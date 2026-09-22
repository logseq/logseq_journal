(ns asset-interop
  (:require [frontend.common.crypt :as crypt]
            [cognitect.transit :as transit]
            [promesa.core :as p]
            ["node:fs" :as fs]
            ["node:path" :as path]))

(let [[mode directory] *command-line-args*
      file (fn [name] (path/join directory name))
      read-bytes (fn [name] (js/Uint8Array. (fs/readFileSync (file name))))
      writer (transit/writer :json)
      reader (transit/reader :json)]
  (->
   (p/let [key (crypt/<import-aes-key (read-bytes "key.bin"))]
     (p/loop [sizes [0 1 256 4097 131057 8388608]]
       (when-let [size (first sizes)]
         (let [plaintext (read-bytes (str size ".bin"))]
           (p/let [_ (if (= mode "generate")
                      (p/let [encrypted (crypt/<encrypt-uint8array key plaintext)]
                        (fs/writeFileSync (file (str size ".upstream.transit"))
                                          (transit/write writer encrypted)))
                      (p/let [envelope (transit/read reader
                                                    (fs/readFileSync (file (str size ".journal.transit")) "utf8"))
                              decrypted (crypt/<decrypt-uint8array key envelope)]
                        (when-not (and (instance? js/Uint8Array decrypted)
                                       (.equals (js/Buffer.from plaintext) (js/Buffer.from decrypted)))
                          (throw (js/Error. (str "Upstream decrypt mismatch: " size))))
                        (println "Upstream decrypt:" size "bytes")))]
             (p/recur (rest sizes)))))))
   (p/catch (fn [error]
              (js/console.error error)
              (set! (.-exitCode js/process) 1)))))
