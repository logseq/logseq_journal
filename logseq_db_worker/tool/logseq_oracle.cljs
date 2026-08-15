(ns logseq-db-worker.tool.logseq-oracle
  (:require
   [cognitect.transit :as transit]
   [clojure.string :as string]
   [promesa.core :as p]
   ["child_process" :as child-process]
   ["fs" :as fs]
   ["os" :as os]
   ["path" :as node-path]))

(def ^:private pinned-schema "65.33")
(def ^:private oracle-format-version 1)
(def ^:private graph-name "logseq-db-worker-oracle")
(def ^:private page-title "Oracle Page")
(def ^:private page-uuid "11111111-1111-4111-8111-111111111111")
(def ^:private parent-uuid "22222222-2222-4222-8222-222222222222")
(def ^:private first-child-uuid "33333333-3333-4333-8333-333333333334")
(def ^:private second-child-uuid "44444444-4444-4444-8444-444444444445")
(def ^:private sibling-uuid "55555555-5555-4555-8555-555555555555")
(def ^:private inserted-uuid "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
(def ^:private continuation-uuid "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
(def ^:private created-page-uuid "66666666-6666-4666-8666-666666666666")
(def ^:private created-class-uuid "77777777-7777-4777-8777-777777777777")
(def ^:private created-journal-uuid "00000001-2024-0102-0000-000000000000")
(def ^:private page-continuation-uuid "88888888-8888-4888-8888-888888888888")
(def ^:private closed-value-uuid "93000000-0000-4000-8000-000000000001")
(def ^:private associated-value-uuid "93000000-0000-4000-8000-000000000002")
(def ^:private checkbox-property :user.property/parity-checkbox)
(def ^:private many-property :user.property/parity-many)
(def ^:private default-property :user.property/parity-default)
(def ^:private created-property :user.property/parity-created)
(def ^:private referring-page-uuid "99999999-9999-4999-8999-999999999991")
(def ^:private referring-block-uuid "99999999-9999-4999-8999-999999999992")
(def ^:private engine-clock-epoch-ms "1704067200000")
(def ^:private transit-writer (transit/writer :json))
(def ^:private transit-reader (transit/reader :json))

(def ^:private projection-pattern
  [:db/ident
   :block/uuid
   :block/title
   :block/name
   :block/order
   :block/journal-day
   :block/collapsed?
   :block/warning
   :block/created-at
   :block/updated-at
   :block/tx-id
   :block/properties
   :block/link
   :logseq.property/deleted-at
   :logseq.property.recycle/original-order
   {:block/parent [:db/ident :block/uuid]}
   {:block/page [:db/ident :block/uuid]}
   {:block/refs [:db/ident :block/uuid]}
   {:block/tags [:db/ident :block/uuid]}
   {:block/alias [:db/ident :block/uuid]}
   {:logseq.property.recycle/original-parent [:db/ident :block/uuid]}
   {:logseq.property.recycle/original-page [:db/ident :block/uuid]}
   {:logseq.property.class/extends [:db/ident :block/uuid]}
   {:block/closed-value-property [:db/ident :block/uuid]}])

(def ^:private property-projection-pattern
  (into projection-pattern
        [:db/cardinality
         :db/valueType
         :db/index
         :logseq.property/type
         :logseq.property/hide?
         :logseq.property/public?
         :logseq.property/value
         :logseq.property/icon
         :user.property/parity-checkbox
         :user.property/parity-many
         {:logseq.property.class/properties [:db/ident :block/uuid]}
         {:logseq.property/default-value [:db/ident :block/uuid]}
         {:logseq.property/created-from-property [:db/ident :block/uuid]}
         {:user.property/parity-default [:db/ident :block/uuid]}]))

(defn- fail!
  [message data]
  (throw (ex-info message data)))

(defn- parse-args
  [args]
  (loop [remaining args
         parsed {}]
    (if-let [arg (first remaining)]
      (cond
        (contains? #{"generate" "verify" "structural" "pages" "properties"} arg)
        (if (:command parsed)
          (fail! "Only one oracle command is allowed." {:args args})
          (recur (rest remaining) (assoc parsed :command arg)))

        (= "--expected-logseq-commit" arg)
        (if-let [value (second remaining)]
          (recur (nnext remaining) (assoc parsed :expected-commit value))
          (fail! "--expected-logseq-commit requires a value." {}))

        (= "--output" arg)
        (if-let [value (second remaining)]
          (recur (nnext remaining) (assoc parsed :output value))
          (fail! "--output requires a value." {}))

        (= "--case" arg)
        (if-let [value (second remaining)]
          (recur (nnext remaining) (assoc parsed :case value))
          (fail! "--case requires a value." {}))

        (= "--database-input" arg)
        (if-let [value (second remaining)]
          (recur (nnext remaining) (assoc parsed :database-input value))
          (fail! "--database-input requires a value." {}))

        (= "--database-output" arg)
        (if-let [value (second remaining)]
          (recur (nnext remaining) (assoc parsed :database-output value))
          (fail! "--database-output requires a value." {}))

        (= "--storage-output" arg)
        (if-let [value (second remaining)]
          (recur (nnext remaining) (assoc parsed :storage-output value))
          (fail! "--storage-output requires a value." {}))

        :else
        (fail! "Unknown oracle argument." {:argument arg}))
      (let [parsed (update parsed :command #(or % "verify"))]
        (when-not (seq (:expected-commit parsed))
          (fail! "--expected-logseq-commit is required." {}))
        (when (and (= "generate" (:command parsed))
                   (not (seq (:output parsed))))
          (fail! "--output is required for generate." {}))
        (when (and (contains? #{"structural" "pages" "properties"} (:command parsed))
                   (not (seq (:case parsed))))
          (fail! "--case is required for parity commands." {}))
        (when (and (contains? #{"structural" "pages" "properties"} (:command parsed))
                   (not (seq (:output parsed))))
          (fail! "--output is required for parity commands." {}))
        (when (and (contains? #{"structural" "pages" "properties"} (:command parsed))
                   (not (seq (:database-output parsed))))
          (fail! "--database-output is required for parity commands." {}))
        parsed))))

(defn- git-output
  [root args]
  (string/trim
   (.execFileSync child-process
                  "git"
                  (clj->js args)
                  #js {:cwd root :encoding "utf8"})))

(defn- verify-oracle-worktree!
  [expected-commit]
  (let [root (git-output (.cwd js/process) ["rev-parse" "--show-toplevel"])
        head (git-output root ["rev-parse" "HEAD"])
        status (git-output root ["status" "--porcelain=v1" "--untracked-files=all"])
        worker-script (node-path/join root "static" "db-worker-node.js")]
    (when-not (= expected-commit head)
      (fail! "The Logseq oracle worktree is at the wrong commit."
             {:expected expected-commit :actual head}))
    (when (seq status)
      (fail! "The Logseq oracle worktree is not clean."
             {:status status}))
    (when-not (.existsSync fs worker-script)
      (fail! "The pinned db-worker-node build is missing."
             {:expectedPath worker-script
              :buildCommand "pnpm db-worker-node:compile"}))
    {:root root :head head :worker-script worker-script}))

(defn- method-name
  [method]
  (subs (str method) 1))

(defn- <delay
  [milliseconds]
  (p/create (fn [resolve _]
              (js/setTimeout resolve milliseconds))))

(defn- parse-server-port
  [server-list-path]
  (when (.existsSync fs server-list-path)
    (some->> (.readFileSync fs server-list-path "utf8")
             string/split-lines
             (keep #(second (re-matches #"\d+\s+(\d+)" %)))
             last
             js/parseInt)))

(defn- <wait-for-server
  [server-list-path child-error deadline]
  (cond
    @child-error
    (p/rejected @child-error)

    (parse-server-port server-list-path)
    (p/resolved (parse-server-port server-list-path))

    (> (js/Date.now) deadline)
    (p/rejected (ex-info "Timed out waiting for db-worker-node."
                         {:serverList server-list-path}))

    :else
    (p/let [_ (<delay 50)]
      (<wait-for-server server-list-path child-error deadline))))

(defn- <request-json
  [url options]
  (p/let [response (js/fetch url (clj->js options))
          body (.text response)
          payload (when (seq body)
                    (js->clj (js/JSON.parse body) :keywordize-keys true))]
    (when-not (.-ok response)
      (fail! (str "db-worker-node request failed: " body)
             {:url url :status (.-status response) :body body}))
    payload))

(defn- <import-database
  [port database-path]
  (p/let [response (js/fetch
                    (str "http://127.0.0.1:" port
                         "/v1/import-db-binary?repo="
                         (js/encodeURIComponent graph-name))
                    #js {:method "POST"
                         :headers #js {"content-type" "application/octet-stream"}
                         :body (.readFileSync fs (node-path/resolve database-path))})
          body (.text response)
          payload (when (seq body)
                    (js->clj (js/JSON.parse body) :keywordize-keys true))]
    (when-not (.-ok response)
      (fail! "db-worker-node database import failed."
             {:database database-path
              :status (.-status response)
              :payload payload}))
    (when-not (:ok payload)
      (fail! "db-worker-node rejected database import."
             {:database database-path :payload payload}))
    payload))

(defn- <invoke
  [port method args]
  (p/let [payload (<request-json
                    (str "http://127.0.0.1:" port "/v1/invoke")
                    {:method "POST"
                     :headers {"content-type" "application/json"}
                     :body (js/JSON.stringify
                            (clj->js
                             {:method (method-name method)
                              :argsTransit (transit/write transit-writer args)}))})
          _ (when-not (:ok payload)
              (fail! "db-worker-node invocation failed."
                     {:method method :payload payload}))
          decoded (transit/read transit-reader (:resultTransit payload))]
    (when (instance? js/Error decoded)
      (throw decoded))
    decoded))

(defn- json-key
  [value]
  (cond
    (keyword? value) (if-let [namespace (namespace value)]
                       (str namespace "/" (name value))
                       (name value))
    (string? value) value
    :else (str value)))

(declare canonicalize)

(defn- canonicalize-map
  [value]
  (reduce-kv
   (fn [result key item]
     (if (= :db/id key)
       result
       (assoc result
              (json-key key)
              (if (contains? #{:block/created-at
                               :block/updated-at
                               :logseq.property/deleted-at} key)
                "$normalizedEpochMs"
                (if (= :block/tx-id key)
                  "$normalizedTransactionId"
                  (canonicalize item))))))
   (sorted-map)
   value))

(defn- canonicalize
  [value]
  (cond
    (nil? value) nil
    (uuid? value) (str value)
    (keyword? value) (json-key value)
    (map? value) (canonicalize-map value)
    (set? value) (->> value (map canonicalize) (sort-by pr-str) vec)
    (sequential? value) (mapv canonicalize value)
    (instance? js/Date value) (.toISOString value)
    (or (string? value) (number? value) (boolean? value)) value
    :else (str value)))

(defn- entity-sort-key
  [entity]
  [(get entity "block/uuid" "")
   (get entity "db/ident" "")
   (get entity "block/name" "")
   (get entity "block/title" "")])

(defn- canonical-projection
  [rows]
  (->> rows
       (map canonicalize)
       (sort-by entity-sort-key)
       vec))

(defn- projection-query
  []
  {:find [[(list 'pull '?entity projection-pattern) '...]]
   :where '[[?entity :block/uuid]]})

(defn- property-projection-query
  []
  {:find [[(list 'pull '?entity property-projection-pattern) '...]]
   :where '[[?entity :block/uuid]]})

(def ^:private schema-query
  '[:find ?version .
    :where
    [?entity :db/ident :logseq.kv/schema-version]
    [?entity :kv/value ?version]])

(defn- <apply-ops
  [port ops]
  (<invoke port :thread-api/apply-outliner-ops [graph-name ops {}]))

(defn- <create-structural-base
  [port]
  (p/let [_ (<apply-ops
             port
             [[:create-page [page-title {:uuid (uuid page-uuid)
                                         :split-namespace? false}]]])
          _ (<apply-ops
             port
             [[:insert-blocks [[{:block/uuid (uuid parent-uuid)
                                 :block/title "Parent"}]
                               (uuid page-uuid)
                               {:sibling? false
                                :keep-uuid? true}]]])
          _ (<apply-ops
             port
             [[:insert-blocks [[{:block/uuid (uuid first-child-uuid)
                                 :block/title "First child"}
                                {:block/uuid (uuid second-child-uuid)
                                 :block/title "Second child"}]
                               (uuid parent-uuid)
                               {:sibling? false
                                :keep-uuid? true}]]])
          _ (<apply-ops
             port
             [[:insert-blocks [[{:block/uuid (uuid sibling-uuid)
                                 :block/title "Sibling"}]
                               (uuid parent-uuid)
                               {:sibling? true
                                :keep-uuid? true}]]])]
    nil))

(defn- <apply-structural-case
  [port case-name]
  (case case-name
    ("base" "inspect")
    (p/resolved nil)

    "save"
    (<apply-ops
     port
     [[:save-block [{:block/uuid (uuid parent-uuid)
                     :block/title "Saved by parity"}
                    {}]]])

    "insert"
    (<apply-ops
     port
     [[:insert-blocks [[{:block/uuid (uuid inserted-uuid)
                         :block/title "Inserted by parity"}]
                       (uuid sibling-uuid)
                       {:sibling? true
                        :keep-uuid? true}]]])

    "move"
    (<apply-ops
     port
     [[:move-blocks [[(uuid second-child-uuid)]
                     (uuid sibling-uuid)
                     {:sibling? true}]]])

    "move-up"
    (<apply-ops
     port
     [[:move-blocks-up-down [[(uuid sibling-uuid)] true]]])

    "indent"
    (<apply-ops
     port
     [[:indent-outdent-blocks [[(uuid sibling-uuid)] true {}]]])

    "outdent"
    (<apply-ops
     port
     [[:indent-outdent-blocks [[(uuid second-child-uuid)]
                               false
                               {:parent-original nil
                                :logical-outdenting? nil}]]])

    "delete"
    (<apply-ops port [[:delete-blocks [[(uuid first-child-uuid)] {}]]])

    "continue"
    (<apply-ops
     port
     [[:insert-blocks [[{:block/uuid (uuid continuation-uuid)
                         :block/title "Continued by Logseq"}]
                       (uuid sibling-uuid)
                       {:sibling? true
                        :keep-uuid? true}]]])

    (fail! "Unknown structural oracle case." {:case case-name})))

(defn- <create-page-base
  [port]
  (p/let [_ (<create-structural-base port)
          _ (<apply-ops
             port
             [[:create-page ["Referring Page" {:uuid (uuid referring-page-uuid)
                                                :split-namespace? false}]]])
          _ (<apply-ops
             port
             [[:insert-blocks [[{:block/uuid (uuid referring-block-uuid)
                                 :block/title "See [[Oracle Page]]"}]
                               (uuid referring-page-uuid)
                               {:sibling? false
                                :keep-uuid? true}]]])]
    nil))

(defn- <apply-page-case
  [port case-name]
  (case case-name
    ("base" "inspect")
    (p/resolved nil)

    "recycled-base"
    (<apply-ops port [[:delete-page [(uuid page-uuid) {}]]])

    "create-ordinary"
    (<apply-ops
     port
     [[:create-page ["Created by parity" {:uuid (uuid created-page-uuid)
                                           :split-namespace? false}]]])

    "create-journal"
    (<apply-ops
     port
     [[:create-page ["Jan 2nd, 2024" {:journal? true
                                      :uuid (uuid created-journal-uuid)}]]])

    "create-class"
    (<apply-ops
     port
     [[:create-page ["Created Class" {:class? true
                                      :uuid (uuid created-class-uuid)}]]])

    "rename"
    (<apply-ops port [[:rename-page [(uuid page-uuid) "Renamed by parity"]]])

    "delete"
    (<apply-ops port [[:delete-page [(uuid page-uuid) {}]]])

    "restore"
    (<apply-ops port [[:restore-recycled [(uuid page-uuid)]]])

    "permanent-delete"
    (<apply-ops port [[:recycle-delete-permanently [(uuid page-uuid)]]])

    "continue"
    (<apply-ops
     port
     [[:create-page ["Continued by Logseq" {:uuid (uuid page-continuation-uuid)
                                             :split-namespace? false}]]])

    (fail! "Unknown page oracle case." {:case case-name})))

(defn- property-schema
  [type cardinality]
  {:logseq.property/type type
   :db/cardinality cardinality
   :logseq.property/hide? false
   :logseq.property/public? true})

(defn- <create-property-base
  [port]
  (p/let [_ (<create-structural-base port)
          _ (<apply-ops
             port
             [[:create-page ["Parity Class" {:class? true
                                              :uuid (uuid created-class-uuid)}]]])
          _ (<apply-ops
             port
             [[:upsert-property
               [checkbox-property
                (property-schema :checkbox :db.cardinality/one)
                {:property-name "Parity Checkbox"}]]
              [:upsert-property
               [many-property
                (property-schema :string :db.cardinality/many)
                {:property-name "Parity Many"}]]
              [:upsert-property
               [default-property
                (property-schema :default :db.cardinality/one)
                {:property-name "Parity Default"}]]])]
    nil))

(defn- <create-property-case-base
  [port case-name]
  (p/let [_ (<create-property-base port)
          _ (case case-name
              ("set-base" "remove")
              (<apply-ops
               port
               [[:set-block-property
                 [(uuid parent-uuid) checkbox-property true]]])

              ("many-base" "batch-replace" "batch-remove")
              (<apply-ops
               port
               [[:batch-set-property
                 [[(uuid parent-uuid) (uuid sibling-uuid)]
                  many-property
                  ["seed"]
                  {}]]])

              ("closed-base" "closed-update" "closed-delete")
              (<apply-ops
               port
               [[:upsert-closed-value
                 [default-property
                  {:id (uuid closed-value-uuid)
                   :value "Choice"
                   :icon nil}]]])

              ("associated-base" "closed-associate")
              (<apply-ops
               port
               [[:create-property-text-block
                 [nil
                  default-property
                  "Associated"
                  {:new-block-id (uuid associated-value-uuid)
                   :set-block-property? false}]]])

              ("class-base" "class-remove")
              (<apply-ops
               port
               [[:class-add-property
                 [(uuid created-class-uuid) checkbox-property]]])

              (p/resolved nil))]
    nil))

(defn- <apply-property-case
  [port case-name]
  (case case-name
    ("base" "set-base" "many-base" "closed-base" "associated-base"
     "class-base" "inspect")
    (p/resolved nil)

    "upsert"
    (<apply-ops
     port
     [[:upsert-property
       [created-property
        (property-schema :number :db.cardinality/one)
        {:property-name "Parity Created"}]]])

    "set"
    (<apply-ops
     port
     [[:set-block-property [(uuid parent-uuid) checkbox-property true]]])

    "remove"
    (<apply-ops
     port
     [[:remove-block-property [(uuid parent-uuid) checkbox-property]]])

    "batch-append"
    (<apply-ops
     port
     [[:batch-set-property
       [[(uuid parent-uuid) (uuid sibling-uuid)] many-property "one" {}]]])

    "batch-replace"
    (<apply-ops
     port
     [[:batch-set-property
       [[(uuid parent-uuid) (uuid sibling-uuid)]
        many-property
        ["two" "three"]
        {}]]])

    "batch-remove"
    (<apply-ops
     port
     [[:batch-remove-property
       [[(uuid parent-uuid) (uuid sibling-uuid)] many-property]]])

    "closed-add"
    (<apply-ops
     port
     [[:upsert-closed-value
       [default-property
        {:id (uuid closed-value-uuid) :value "Choice" :icon nil}]]])

    "closed-update"
    (<apply-ops
     port
     [[:upsert-closed-value
       [default-property
        {:id (uuid closed-value-uuid) :value "Updated" :icon nil}]]])

    "closed-associate"
    (<apply-ops
     port
     [[:add-existing-values-to-closed-values
       [default-property [(uuid associated-value-uuid)]]]])

    "closed-delete"
    (<apply-ops
     port
     [[:delete-closed-value [default-property (uuid closed-value-uuid)]]])

    "class-add"
    (<apply-ops
     port
     [[:class-add-property [(uuid created-class-uuid) checkbox-property]]])

    "class-remove"
    (<apply-ops
     port
     [[:class-remove-property [(uuid created-class-uuid) checkbox-property]]])

    "continue"
    (<apply-ops
     port
     [[:set-block-property [(uuid sibling-uuid) checkbox-property true]]])

    (fail! "Unknown property oracle case." {:case case-name})))

(defn- golden
  [commit actual-schema projection]
  {:formatVersion oracle-format-version
   :case "worker-create-page"
   :source {:logseqCommit commit
            :schema (if-let [minor (:minor actual-schema)]
                      (str (:major actual-schema) "." minor)
                      (str (:major actual-schema)))
            :minimumSupportedSchema pinned-schema
            :workerRoute "frontend.worker.db-core -> thread-api/apply-outliner-ops"}
   :deterministicInputs {:engineClockEpochMs engine-clock-epoch-ms
                         :pageUuid page-uuid
                         :pageTitle page-title}
   :normalizationRules ["Remove DataScript :db/id storage addresses."
                        "Replace :block/created-at and :block/updated-at with $normalizedEpochMs."
                        "Replace :block/tx-id with $normalizedTransactionId."
                        "Sort sets and projected entities by stable semantic identity."]
   :projection projection})

(defn- structural-golden
  [commit actual-schema case-name projection]
  (assoc (golden commit actual-schema projection)
         :case (str "structural-" case-name)
         :deterministicInputs
         {:engineClockEpochMs engine-clock-epoch-ms
          :pageUuid page-uuid
          :parentUuid parent-uuid
          :firstChildUuid first-child-uuid
          :secondChildUuid second-child-uuid
          :siblingUuid sibling-uuid
          :insertedUuid inserted-uuid
          :continuationUuid continuation-uuid}))

(defn- page-golden
  [commit actual-schema case-name projection]
  (assoc (golden commit actual-schema projection)
         :case (str "pages-" case-name)
         :deterministicInputs
         {:engineClockEpochMs engine-clock-epoch-ms
          :pageUuid page-uuid
          :createdPageUuid created-page-uuid
          :createdJournalUuid created-journal-uuid
          :createdClassUuid created-class-uuid
          :pageContinuationUuid page-continuation-uuid
          :referringPageUuid referring-page-uuid
          :referringBlockUuid referring-block-uuid}))

(defn- property-golden
  [commit actual-schema case-name projection]
  (assoc (golden commit actual-schema projection)
         :case (str "properties-" case-name)
         :deterministicInputs
         {:engineClockEpochMs engine-clock-epoch-ms
          :pageUuid page-uuid
          :parentUuid parent-uuid
          :siblingUuid sibling-uuid
          :classUuid created-class-uuid
          :closedValueUuid closed-value-uuid
          :associatedValueUuid associated-value-uuid
          :checkboxProperty (str checkbox-property)
          :manyProperty (str many-property)
          :defaultProperty (str default-property)
          :createdProperty (str created-property)}))

(defn- write-golden!
  [output value]
  (let [output (node-path/resolve output)]
    (.mkdirSync fs (node-path/dirname output) #js {:recursive true})
    (.writeFileSync fs
                    output
                    (str (js/JSON.stringify (clj->js value) nil 2) "\n")
                    "utf8")
    output))

(defn- write-storage-fixture!
  [database-path output commit actual-schema]
  (let [rows-json (.execFileSync
                   child-process
                   "sqlite3"
                   (clj->js ["-json"
                             database-path
                             "SELECT addr, content, addresses FROM kvs ORDER BY addr"])
                   #js {:encoding "utf8"})
        rows (js->clj (js/JSON.parse rows-json) :keywordize-keys true)]
    (write-golden!
     output
     {:formatVersion oracle-format-version
      :source {:logseqCommit commit
               :schema (if-let [minor (:minor actual-schema)]
                         (str (:major actual-schema) "." minor)
                         (str (:major actual-schema)))}
      :tableSql "CREATE TABLE kvs (addr INTEGER primary key, content TEXT, addresses JSON);"
      :rows rows})))

(defn- <await-child-exit
  [child]
  (if (some? (.-exitCode child))
    (p/resolved nil)
    (p/create
     (fn [resolve reject]
       (let [terminate-timer (js/setTimeout
                              (fn []
                                (when (nil? (.-exitCode child))
                                  (.kill child "SIGTERM")))
                              1000)
             kill-timer (js/setTimeout
                         (fn []
                           (when (nil? (.-exitCode child))
                             (.kill child "SIGKILL")))
                         3000)
             timeout-timer (js/setTimeout
                            (fn []
                              (reject (ex-info "Timed out stopping db-worker-node." {})))
                            5000)]
         (.once child
                "exit"
                (fn [_code _signal]
                  (js/clearTimeout terminate-timer)
                  (js/clearTimeout kill-timer)
                  (js/clearTimeout timeout-timer)
                  (resolve nil))))))))

(defn- <stop-worker
  [port child temp-root]
  (p/let [_ (if port
              (-> (<request-json (str "http://127.0.0.1:" port "/v1/shutdown")
                                 {:method "POST"})
                  (p/catch (fn [_]
                             (when (nil? (.-exitCode child))
                               (.kill child "SIGTERM")))))
              (do
                (when (nil? (.-exitCode child))
                  (.kill child "SIGTERM"))
                (p/resolved nil)))
          _ (<await-child-exit child)]
    (.rmSync fs temp-root #js {:recursive true :force true})))

(defn- spawn-worker
  [root worker-script temp-root premature-exit-message]
  (let [server-list-path (node-path/join temp-root "server-list")
        child-error (atom nil)
        stderr (atom "")
        child (.spawn child-process
                      (.-execPath js/process)
                      (clj->js [worker-script
                                "--root-dir" temp-root
                                "--repo" graph-name
                                "--owner-source" "unknown"
                                "--log-level" "error"])
                      #js {:cwd root
                           :env (js/Object.assign
                                 #js {}
                                 (.-env js/process)
                                 #js {"LOGSEQ_STABLE_IDENTS" "1"})
                           :stdio #js ["ignore" "ignore" "pipe"]})
        port* (atom nil)]
    (.on (.-stderr child) "data" #(swap! stderr str (.toString %)))
    (.on child "error" #(reset! child-error %))
    (.on child "exit"
         (fn [code _signal]
           (when (and (not= 0 code) (nil? @child-error))
             (reset! child-error
                     (ex-info premature-exit-message
                              {:exitCode code :stderr @stderr})))))
    {:server-list-path server-list-path
     :child-error child-error
     :child child
     :port* port*}))

(defn- <generate!
  [{:keys [root head worker-script]} output database-output storage-output]
  (let [temp-root (.mkdtempSync fs (node-path/join (.tmpdir os) "logseq-db-worker-oracle-"))
        {:keys [server-list-path child-error child port*]}
        (spawn-worker
         root
         worker-script
         temp-root
         "db-worker-node exited before the oracle completed.")]
    (->
     (p/let [port (<wait-for-server server-list-path child-error (+ (js/Date.now) 30000))
             _ (reset! port* port)
             _ (<invoke port
                        :thread-api/apply-outliner-ops
                        [graph-name
                         [[:create-page [page-title {:uuid (uuid page-uuid)
                                                    :split-namespace? false}]]]
                         {}])
             rows (<invoke port :thread-api/q [graph-name [(projection-query)]])
             actual-schema (<invoke port :thread-api/q [graph-name [schema-query]])
             fixture-database (when (or database-output storage-output)
                                (node-path/resolve
                                 (or database-output
                                     (node-path/join temp-root "oracle-backup.sqlite"))))
             _ (when fixture-database
                 (.mkdirSync fs (node-path/dirname fixture-database) #js {:recursive true})
                 (<invoke port
                          :thread-api/backup-db-sqlite
                          [graph-name fixture-database]))
             _ (when storage-output
                 (write-storage-fixture!
                  fixture-database
                  storage-output
                  head
                  actual-schema))
             output-path (write-golden!
                          output
                          (golden head actual-schema (canonical-projection rows)))]
       (println output-path))
     (p/finally
      (fn []
        (<stop-worker @port* child temp-root))))))

(defn- <structural!
  [{:keys [root head worker-script]}
   case-name
   database-input
   database-output
   output]
  (let [temp-root (.mkdtempSync fs (node-path/join (.tmpdir os) "logseq-db-worker-structural-"))
        {:keys [server-list-path child-error child port*]}
        (spawn-worker
         root
         worker-script
         temp-root
         "db-worker-node exited before the structural oracle completed.")]
    (->
     (p/let [port (<wait-for-server server-list-path child-error (+ (js/Date.now) 30000))
             _ (reset! port* port)
             _ (if database-input
                 (<import-database port database-input)
                 (<create-structural-base port))
             _ (<apply-structural-case port case-name)
             rows (<invoke port :thread-api/q [graph-name [(projection-query)]])
             actual-schema (<invoke port :thread-api/q [graph-name [schema-query]])
             database-output (node-path/resolve database-output)
             _ (.mkdirSync fs (node-path/dirname database-output) #js {:recursive true})
             _ (<invoke port
                        :thread-api/backup-db-sqlite
                        [graph-name database-output])
             output-path (write-golden!
                          output
                          (structural-golden
                           head
                           actual-schema
                           case-name
                           (canonical-projection rows)))]
       (println output-path))
     (p/finally
      (fn []
        (<stop-worker @port* child temp-root))))))

(defn- <pages!
  [{:keys [root head worker-script]}
   case-name
   database-input
   database-output
   output]
  (let [temp-root (.mkdtempSync fs (node-path/join (.tmpdir os) "logseq-db-worker-pages-"))
        {:keys [server-list-path child-error child port*]}
        (spawn-worker
         root
         worker-script
         temp-root
         "db-worker-node exited before the page oracle completed.")]
    (->
     (p/let [port (<wait-for-server server-list-path child-error (+ (js/Date.now) 30000))
             _ (reset! port* port)
             _ (if database-input
                 (<import-database port database-input)
                 (<create-page-base port))
             _ (<apply-page-case port case-name)
             rows (<invoke port :thread-api/q [graph-name [(projection-query)]])
             actual-schema (<invoke port :thread-api/q [graph-name [schema-query]])
             database-output (node-path/resolve database-output)
             _ (.mkdirSync fs (node-path/dirname database-output) #js {:recursive true})
             _ (<invoke port
                        :thread-api/backup-db-sqlite
                        [graph-name database-output])
             output-path (write-golden!
                          output
                          (page-golden
                           head
                           actual-schema
                           case-name
                           (canonical-projection rows)))]
       (println output-path))
     (p/finally
      (fn []
        (<stop-worker @port* child temp-root))))))

(defn- <properties!
  [{:keys [root head worker-script]}
   case-name
   database-input
   database-output
   output]
  (let [temp-root (.mkdtempSync fs (node-path/join (.tmpdir os) "logseq-db-worker-properties-"))
        {:keys [server-list-path child-error child port*]}
        (spawn-worker
         root
         worker-script
         temp-root
         "db-worker-node exited before the property oracle completed.")]
    (->
     (p/let [port (<wait-for-server server-list-path child-error (+ (js/Date.now) 30000))
             _ (reset! port* port)
             _ (if database-input
                 (<import-database port database-input)
                 (<create-property-case-base port case-name))
             _ (<apply-property-case port case-name)
             rows (<invoke port :thread-api/q [graph-name [(property-projection-query)]])
             actual-schema (<invoke port :thread-api/q [graph-name [schema-query]])
             database-output (node-path/resolve database-output)
             _ (.mkdirSync fs (node-path/dirname database-output) #js {:recursive true})
             _ (<invoke port
                        :thread-api/backup-db-sqlite
                        [graph-name database-output])
             output-path (write-golden!
                          output
                          (property-golden
                           head
                           actual-schema
                           case-name
                           (canonical-projection rows)))]
       (println output-path))
     (p/finally
      (fn []
        (<stop-worker @port* child temp-root))))))

(defn- main
  []
  (let [{:keys [command expected-commit output database-input database-output
                storage-output]
         case-name :case}
        (parse-args *command-line-args*)
        verified (verify-oracle-worktree! expected-commit)]
    (case command
      "verify"
      (println
       (js/JSON.stringify
        (clj->js {:ok true
                  :logseqCommit (:head verified)
                  :minimumSupportedSchema pinned-schema})))

      "generate"
      (<generate! verified output database-output storage-output)

      "structural"
      (<structural!
       verified
       case-name
       database-input
       database-output
       output)

      "pages"
      (<pages!
       verified
       case-name
       database-input
       database-output
       output)

      "properties"
      (<properties!
       verified
       case-name
       database-input
       database-output
       output))))

(-> (main)
    (p/catch
     (fn [error]
       (.error js/console (or (ex-message error) (.-message error) (str error)))
       (when-let [data (ex-data error)]
         (.error js/console (js/JSON.stringify (clj->js data))))
       (set! (.-exitCode js/process) 1))))
