#!/usr/bin/env bb
;; Toy "server" for each node. Listens on loopback only — the only way in is
;; through tsproxy (tailnet ingress), which injects verified X-Tailnet-* headers.
;;
;;   GET /             -> who am I, and who (per tailnet identity) called me
;;   GET /call/<peer>  -> call <peer>'s "/" through the egress proxy
(require '[org.httpkit.server :as srv]
         '[babashka.http-client :as http]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def role   (or (System/getenv "ROLE") "unknown"))
(def egress (or (System/getenv "EGRESS_URL") "http://127.0.0.1:9000"))
(def port   (parse-long (or (System/getenv "APP_PORT") "8080")))

(defn caller [req]
  (let [h (:headers req)]
    {:node (get h "x-tailnet-node")
     :tags (some-> (get h "x-tailnet-tags") not-empty (str/split #","))
     :user (get h "x-tailnet-user")}))

(defn json-resp [status body]
  {:status status
   :headers {"content-type" "application/json"}
   :body (json/generate-string body)})

(defn call-peer [peer]
  (try
    (let [resp (http/get (str egress "/" peer "/")
                         {:throw false :timeout 8000})]
      (json-resp (if (= 200 (:status resp)) 200 502)
                 {:from role :peer peer :peer-status (:status resp)
                  :peer-body (try (json/parse-string (:body resp) true)
                                  (catch Exception _ (:body resp)))}))
    (catch Exception e
      (json-resp 502 {:from role :peer peer :error (ex-message e)}))))

(defn handler [{:keys [uri] :as req}]
  (cond
    (= uri "/")
    (let [c (caller req)]
      (if (:node c)
        (json-resp 200 {:node role :caller c})
        ;; No identity => did not come through the tailnet proxy.
        (json-resp 403 {:node role :error "no tailnet identity"})))

    (str/starts-with? uri "/call/")
    (call-peer (subs uri (count "/call/")))

    :else (json-resp 404 {:error "not found"})))

(srv/run-server handler {:ip "127.0.0.1" :port port})
(println (str "[" role "] app listening on 127.0.0.1:" port))
@(promise)
