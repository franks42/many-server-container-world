// tsproxy: joins a tailnet as its own node (via tsnet, fully userspace — no
// TUN device, no NET_ADMIN) and fronts a local app.
//
// Ingress: tailnet :80  -> APP_ADDR, with caller identity from WhoIs injected
//          as X-Tailnet-Node / X-Tailnet-Tags / X-Tailnet-User headers.
//          Any client-supplied X-Tailnet-* headers are stripped first, so the
//          app can trust them.
// Egress:  EGRESS_ADDR (loopback only) — GET /<peer>/<path> is forwarded to
//          http://<peer>:80/<path> over the tailnet. The app never touches the
//          tailnet directly; the peer sees *this* node's tags as the caller.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"time"

	"tailscale.com/tsnet"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	hostname := env("TS_HOSTNAME", "")
	if hostname == "" {
		hostname, _ = os.Hostname()
	}
	if suffix := os.Getenv("TS_HOSTNAME_UNIQUE"); suffix != "" {
		// For `docker compose --scale`: role + container hostname.
		h, _ := os.Hostname()
		hostname = hostname + "-" + h
	}
	if os.Getenv("TS_AUTHKEY") == "" {
		log.Fatal("TS_AUTHKEY is empty (run scripts/up.sh, or set a real Tailscale key)")
	}
	appAddr := env("APP_ADDR", "127.0.0.1:8080")
	egressAddr := env("EGRESS_ADDR", "127.0.0.1:9000")

	s := &tsnet.Server{
		Hostname:   hostname,
		AuthKey:    os.Getenv("TS_AUTHKEY"),
		ControlURL: os.Getenv("TS_CONTROL_URL"), // empty = real Tailscale
		Dir:        env("TS_STATE_DIR", "/var/lib/tsproxy"),
		Ephemeral:  env("TS_EPHEMERAL", "true") == "true",
	}
	if os.Getenv("TS_VERBOSE") != "" {
		s.Logf = log.Printf // full tailscaled-style backend logs
	}
	defer s.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	st, err := s.Up(ctx)
	cancel()
	if err != nil {
		log.Fatalf("tsnet up: %v", err)
	}
	log.Printf("joined tailnet as %s %v", hostname, st.TailscaleIPs)

	// Bare peer names ("api") are qualified with the MagicDNS suffix
	// ("api.world.test"). Otherwise the OS resolver may answer first — in
	// docker compose, "api" is also the *container* name — and the dial
	// silently bypasses the tailnet.
	magicSuffix := ""
	if st.CurrentTailnet != nil {
		magicSuffix = st.CurrentTailnet.MagicDNSSuffix
	}
	qualify := func(peer string) string {
		if magicSuffix == "" || strings.Contains(peer, ".") || net.ParseIP(peer) != nil {
			return peer
		}
		return peer + "." + magicSuffix
	}

	lc, err := s.LocalClient()
	if err != nil {
		log.Fatal(err)
	}

	// ---- ingress -------------------------------------------------------
	appURL := &url.URL{Scheme: "http", Host: appAddr}
	ingress := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(appURL)
			for k := range r.Out.Header {
				if strings.HasPrefix(strings.ToLower(k), "x-tailnet-") {
					r.Out.Header.Del(k)
				}
			}
			who, err := lc.WhoIs(r.In.Context(), r.In.RemoteAddr)
			if err != nil {
				log.Printf("whois %s: %v", r.In.RemoteAddr, err)
				return // app sees no identity headers => must reject
			}
			r.Out.Header.Set("X-Tailnet-Node", who.Node.ComputedName)
			r.Out.Header.Set("X-Tailnet-Tags", strings.Join(who.Node.Tags, ","))
			if who.UserProfile != nil {
				r.Out.Header.Set("X-Tailnet-User", who.UserProfile.LoginName)
			}
		},
	}
	ln, err := s.Listen("tcp", ":80")
	if err != nil {
		log.Fatal(err)
	}
	go func() { log.Fatal(http.Serve(ln, ingress)) }()

	// ---- egress --------------------------------------------------------
	// Egress must stay on the tailnet. tsnet's Dial falls back to the host
	// network for destinations it has no peer for, and the control server
	// only sends peers this node has an ACL relationship with. Without the
	// check below, a call to a non-peer leaves via the host, and if the host
	// is itself on the tailnet, it arrives with the *host's* identity.
	// So: resolve the target against this node's own peer list and dial
	// only that peer's Tailscale IP; anything else is refused.
	peerAddr := func(ctx context.Context, host string) (netip.Addr, error) {
		st, err := lc.Status(ctx)
		if err != nil {
			return netip.Addr{}, err
		}
		ip, ipErr := netip.ParseAddr(host)
		for _, p := range st.Peer {
			fqdn := strings.TrimSuffix(p.DNSName, ".")
			short, _, _ := strings.Cut(fqdn, ".")
			match := strings.EqualFold(fqdn, host) || strings.EqualFold(short, host)
			for _, a := range p.TailscaleIPs {
				match = match || (ipErr == nil && a == ip)
			}
			if !match {
				continue
			}
			for _, a := range p.TailscaleIPs {
				if a.Is4() {
					return a, nil
				}
			}
			if len(p.TailscaleIPs) > 0 {
				return p.TailscaleIPs[0], nil
			}
		}
		return netip.Addr{}, fmt.Errorf("%s is not a tailnet peer of this node (no ACL relationship)", host)
	}

	dialTimeout := 5 * time.Second // an ACL deny is a silent drop, so deny == timeout
	egress := &httputil.ReverseProxy{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				ctx, cancel := context.WithTimeout(ctx, dialTimeout)
				defer cancel()
				host, port, err := net.SplitHostPort(addr)
				if err != nil {
					return nil, err
				}
				ip, err := peerAddr(ctx, host)
				if err != nil {
					return nil, err
				}
				return s.Dial(ctx, network, net.JoinHostPort(ip.String(), port))
			},
			ResponseHeaderTimeout: 10 * time.Second,
		},
		Rewrite: func(r *httputil.ProxyRequest) {
			// /<peer>/<rest>
			p := strings.TrimPrefix(r.In.URL.Path, "/")
			peer, rest, _ := strings.Cut(p, "/")
			r.Out.URL.Scheme = "http"
			peer = qualify(peer)
			r.Out.URL.Host = peer + ":80"
			r.Out.URL.Path = "/" + rest
			r.Out.Host = peer
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("egress %s: %v", r.URL.Path, err)
			http.Error(w, "egress failed: "+err.Error(), http.StatusBadGateway)
		},
	}
	log.Printf("ingress tailnet:80 -> %s, egress %s", appAddr, egressAddr)
	log.Fatal(http.ListenAndServe(egressAddr, egress))
}
