package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type Endpoint struct {
	URI    string            `json:"uri"`    // "/run/:name/*rest"
	Method string            `json:"method"` // "POST"
	Query  map[string]string `json:"query"`  // defaults for query
	Body   map[string]string `json:"body"`   // defaults for body
	Auth   string            `json:"auth"`   // "X-Token:SECRET"
	TTL    string            `json:"ttl"`    // "8s"
	Error  int               `json:"error"`  // http code on error
	Script []string          `json:"script"` // argv with {placeholders}

	// compiled
	pathRe   *regexp.Regexp
	wildcard bool
	header   string
	token    string
	timeout  time.Duration
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func parseAuth(a string) (hdr, tok string, err error) {
	parts := strings.SplitN(a, ":", 2)
	if len(parts) != 2 {
		return "", "", fmt.Errorf("bad auth format, want Header:Token")
	}
	h := strings.TrimSpace(parts[0])
	t := strings.TrimSpace(parts[1])
	if h == "" || t == "" {
		return "", "", fmt.Errorf("empty header/token")
	}
	return h, t, nil
}

func compileURI(pattern string) (*regexp.Regexp, bool, error) {
	segs := strings.Split(strings.TrimPrefix(pattern, "/"), "/")
	var b strings.Builder
	b.WriteString("^")
	wild := false
	for i, s := range segs {
		if s == "" {
			continue
		}
		b.WriteString("/")
		if strings.HasPrefix(s, ":") {
			name := s[1:]
			b.WriteString("(?P<" + name + ">[^/]+)")
		} else if strings.HasPrefix(s, "*") {
			if i != len(segs)-1 {
				return nil, false, fmt.Errorf("wildcard must be last")
			}
			name := s[1:]
			wild = true
			b.WriteString("(?P<" + name + ">.*)")
		} else {
			b.WriteString(regexp.QuoteMeta(s))
		}
	}
	b.WriteString("$")
	re, err := regexp.Compile(b.String())
	return re, wild, err
}

func mustEndpointFromFile(path string) (*Endpoint, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var ep Endpoint
	if err := json.Unmarshal(b, &ep); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	// required
	if ep.URI == "" || ep.Method == "" || ep.Auth == "" || len(ep.Script) == 0 {
		return nil, fmt.Errorf("%s: missing required fields (uri/method/auth/script)", path)
	}
	h, t, err := parseAuth(ep.Auth)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	ep.header, ep.token = h, t
	if ep.TTL == "" {
		ep.TTL = "8s"
	}
	d, err := time.ParseDuration(ep.TTL)
	if err != nil {
		return nil, fmt.Errorf("%s: bad ttl: %v", path, err)
	}
	ep.timeout = d
	if ep.Error == 0 {
		ep.Error = 500
	}
	if ep.Query == nil {
		ep.Query = map[string]string{}
	}
	if ep.Body == nil {
		ep.Body = map[string]string{}
	}
	re, wild, err := compileURI(ep.URI)
	if err != nil {
		return nil, fmt.Errorf("%s: bad uri: %v", path, err)
	}
	ep.pathRe = re
	ep.wildcard = wild
	return &ep, nil
}

func loadEndpoints(dir string) ([]*Endpoint, error) {
	var eps []*Endpoint
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(p))
		if ext != ".json" {
			return nil
		}
		ep, err := mustEndpointFromFile(p)
		if err != nil {
			return err
		}
		eps = append(eps, ep)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(eps) == 0 {
		return nil, fmt.Errorf("no endpoint configs found in %s", dir)
	}
	sort.Slice(eps, func(i, j int) bool { return eps[i].URI < eps[j].URI })
	return eps, nil
}

func pathVars(ep *Endpoint, p string) (map[string]string, bool) {
	m := ep.pathRe.FindStringSubmatch(p)
	if m == nil {
		return nil, false
	}
	out := map[string]string{}
	for i, name := range ep.pathRe.SubexpNames() {
		if i == 0 || name == "" {
			continue
		}
		out[name] = m[i]
	}
	return out, true
}

func toString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case json.Number:
		return t.String()
	case float64:
		s := fmt.Sprintf("%f", t)
		s = strings.TrimRight(s, "0")
		s = strings.TrimRight(s, ".")
		return s
	case bool:
		if t {
			return "true"
		}
		return "false"
	default:
		b, _ := json.Marshal(t)
		return string(b)
	}
}

func mergeParams(ep *Endpoint, pv map[string]string, r *http.Request) map[string]string {
	params := map[string]string{}
	// defaults
	for k, v := range ep.Query {
		params[k] = v
	}
	for k, v := range ep.Body {
		params[k] = v
	}
	// path
	for k, v := range pv {
		params[k] = v
	}
	// query
	q := r.URL.Query()
	for k := range q {
		params[k] = q.Get(k)
	}
	// body json
	if r.Body != nil {
		defer r.Body.Close()
		var body map[string]any
		dec := json.NewDecoder(r.Body)
		dec.UseNumber()
		if err := dec.Decode(&body); err == nil {
			for k, v := range body {
				params[k] = toString(v)
			}
		}
	}
	return params
}

func applyTemplate(tokens []string, params map[string]string) ([]string, error) {
	out := make([]string, len(tokens))
	for i, tok := range tokens {
		res := tok
		for {
			s := strings.Index(res, "{")
			if s < 0 {
				break
			}
			e := strings.Index(res[s+1:], "}")
			if e < 0 {
				return nil, fmt.Errorf("unclosed placeholder in %q", tok)
			}
			e += s + 1
			name := res[s+1 : e]
			val := params[name] // if missing → empty
			res = res[:s] + val + res[e+1:]
		}
		out[i] = res
	}
	return out, nil
}

func main() {
	listen := getenv("LISTEN_ADDR", "10.8.0.1:8080")
	confDir := getenv("CONFIG_DIR", "./conf")

	// strictly IP:port to listen
	if host, _, err := net.SplitHostPort(listen); err != nil || net.ParseIP(host) == nil {
		log.Fatalf("LISTEN_ADDR must be IP:port, got %q", listen)
	}

	eps, err := loadEndpoints(confDir)
	if err != nil {
		log.Fatalf("load endpoints: %v", err)
	}
	log.Printf("loaded %d endpoints", len(eps))

	mux := http.NewServeMux()

	// health
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// single handler: we select the first matching ep by method and uri
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		var ep *Endpoint
		var pv map[string]string
		for _, e := range eps {
			if r.Method != e.Method {
				continue
			}
			if vars, ok := pathVars(e, r.URL.Path); ok {
				ep = e
				pv = vars
				break
			}
		}
		if ep == nil {
			http.NotFound(w, r)
			return
		}
		// auth
		if r.Header.Get(ep.header) != ep.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		// params
		params := mergeParams(ep, pv, r)
		argv, err := applyTemplate(ep.Script, params)
		if err != nil {
			http.Error(w, "bad template: "+err.Error(), http.StatusBadRequest)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), ep.timeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
		// minimal PATH, empty environment
		cmd.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin"}
		out, err := cmd.CombinedOutput()
		if err != nil {
    // non-zero code/timeout → return ep.Error with the output body
		    w.WriteHeader(ep.Error)
		    _, _ = w.Write(out)
		    if errors.Is(err, context.DeadlineExceeded) || ctx.Err() == context.DeadlineExceeded {
		        _, _ = w.Write([]byte("\n(timeout)\n"))
		    }
		    return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(out)
	})

	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("listening on http://%s", listen)
	log.Fatal(srv.ListenAndServe())
}
