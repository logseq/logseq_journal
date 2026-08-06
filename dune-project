(lang dune 3.17)
(name logseq_journal)
(generate_opam_files false)
(license MIT)

(package
 (name logseq_journal)
 (allow_empty)
 (depends
  (ocaml (= 5.1.1))
  (dune (>= 3.17))
  (bonsai_flutter (= 0.1.0~dev))
  (bonsai_flutter_test (= 0.1.0~dev))
  (bonsai_flutter_tool (= 0.1.0~dev))
  (base (and (>= v0.17) (< v0.18~)))
  (bonsai (and (>= v0.17) (< v0.18~)))
  (core (and (>= v0.17) (< v0.18~)))
  (incr_dom (and (>= v0.17) (< v0.18~)))
  (virtual_dom (and (>= v0.17) (< v0.18~)))))
