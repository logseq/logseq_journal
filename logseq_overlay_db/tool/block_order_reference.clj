;; Expected outputs come directly from the pinned library, never a copied algorithm.
;; Run with the source directory of revision 1087f0fb18aa8e25ee3bbbb0db983b7a29bce270
;; on Babashka's classpath; redirect stdout to test/fixtures/order/reference.tsv.
(require '[logseq.clj-fractional-indexing :as f]
         '[clojure.string :as s])

(def max-key (str "z" (apply str (repeat 26 "z"))))
(def explicit
  [[nil nil] ["a0" nil] [nil "a0"] ["a0" "a1"] ["az" nil]
   [nil "b00"] [nil "Y00"] ["Zz" "a1"] ["a0V" "a0W"]
   [nil "a0V"] ["a000000000000000011" "a1"] [max-key nil]
   ["a0zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzV" "a1"]])
(def integers (vec (f/generate-n-keys-between nil "a0" 80)))
(def corpus
  (vec (sort (concat integers
                     (f/generate-n-keys-between nil nil 100)
                     (f/generate-n-keys-between "a0" "a1" 80)))))

(doseq [[a b] (concat explicit
                      (map-indexed (fn [i a] [a (get corpus (inc i))]) corpus))
        n [0 1 2 3 4 9 32]]
  (let [keys (f/generate-n-keys-between a b n)]
    (println (s/join "\t" [(or a "-") (or b "-") n
                           (if (seq keys) (s/join "," keys) "-")]))))
