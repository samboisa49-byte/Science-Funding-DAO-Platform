;; open-data-verification
;; Smart contract ensuring research data publication and reproducibility requirements are met

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-RESEARCH-NOT-FOUND (err u301))
(define-constant ERR-DATA-ALREADY-PUBLISHED (err u302))
(define-constant ERR-INVALID-METADATA (err u303))
(define-constant ERR-INSUFFICIENT-REQUIREMENTS (err u304))
(define-constant ERR-VERIFICATION-FAILED (err u305))
(define-constant ERR-DEADLINE-PASSED (err u306))
(define-constant ERR-INVALID-HASH (err u307))
(define-constant ERR-COMPLIANCE-NOT-MET (err u308))
(define-constant ERR-ALREADY-VERIFIED (err u309))

;; Constants
(define-constant PUBLICATION-DEADLINE u2016) ;; ~2 weeks in blocks
(define-constant MIN-METADATA-LENGTH u50)
(define-constant MAX-METADATA-LENGTH u2000)
(define-constant REPRODUCIBILITY-SCORE-THRESHOLD u80)
(define-constant DATA-RETENTION-PERIOD u525600) ;; ~1 year in blocks

;; Data types for compliance tracking
(define-constant COMPLIANCE-PENDING "pending")
(define-constant COMPLIANCE-VERIFIED "verified")
(define-constant COMPLIANCE-FAILED "failed")
(define-constant COMPLIANCE-EXPIRED "expired")

;; Data structures
(define-map research-data-publications
    { research-id: uint }
    {
        researcher: principal,
        title: (string-ascii 200),
        publication-date: uint,
        data-hash: (buff 32),
        metadata-hash: (buff 32),
        dataset-url: (string-ascii 300),
        license-type: (string-ascii 50),
        access-level: (string-ascii 20), ;; public, restricted, embargo
        compliance-status: (string-ascii 20),
        verification-deadline: uint
    }
)

(define-map data-metadata
    { research-id: uint }
    {
        abstract: (string-ascii 500),
        methodology: (string-ascii 800),
        data-collection-period: (string-ascii 100),
        sample-size: uint,
        variables-count: uint,
        file-formats: (string-ascii 200),
        data-size: uint, ;; in bytes
        keywords: (string-ascii 300),
        doi: (optional (string-ascii 100))
    }
)

(define-map reproducibility-requirements
    { research-id: uint }
    {
        code-repository-url: (string-ascii 300),
        code-hash: (buff 32),
        environment-description: (string-ascii 400),
        dependencies: (string-ascii 500),
        execution-instructions: (string-ascii 600),
        expected-outputs: (string-ascii 400),
        computational-requirements: (string-ascii 300)
    }
)

(define-map verification-records
    { research-id: uint, verifier: principal }
    {
        verification-date: uint,
        data-integrity-score: uint, ;; 1-100
        metadata-completeness-score: uint, ;; 1-100
        reproducibility-score: uint, ;; 1-100
        overall-score: uint, ;; 1-100
        verification-notes: (string-ascii 500),
        passed: bool
    }
)

(define-map compliance-tracking
    { research-id: uint }
    {
        data-published: bool,
        metadata-complete: bool,
        code-available: bool,
        reproducible: bool,
        peer-verified: bool,
        compliance-score: uint,
        last-updated: uint
    }
)

(define-map data-access-logs
    { research-id: uint, accessor: principal, access-date: uint }
    {
        access-type: (string-ascii 20), ;; download, view, cite
        purpose: (string-ascii 100),
        approved: bool
    }
)

;; Variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-publications uint u0)
(define-data-var verified-publications uint u0)
(define-data-var failed-publications uint u0)
(define-data-var authorized-verifiers (list 50 principal) (list tx-sender))

;; Private functions
(define-private (is-authorized-verifier (verifier principal))
    (is-some (index-of (var-get authorized-verifiers) verifier))
)

(define-private (calculate-overall-score (data-score uint) (metadata-score uint) (repro-score uint))
    (/ (+ (* data-score u4) (* metadata-score u3) (* repro-score u3)) u10)
)

(define-private (validate-metadata-completeness (research-id uint))
    (let (
        (metadata (map-get? data-metadata { research-id: research-id }))
    )
        (match metadata
            some-metadata (
                and
                    (> (len (get abstract some-metadata)) MIN-METADATA-LENGTH)
                    (> (len (get methodology some-metadata)) MIN-METADATA-LENGTH)
                    (> (get sample-size some-metadata) u0)
                    (> (get variables-count some-metadata) u0)
                    (> (len (get file-formats some-metadata)) u0)
            )
            false
        )
    )
)

(define-private (check-reproducibility-requirements (research-id uint))
    (let (
        (repro-req (map-get? reproducibility-requirements { research-id: research-id }))
    )
        (match repro-req
            some-req (
                and
                    (> (len (get code-repository-url some-req)) u10)
                    (> (len (get environment-description some-req)) MIN-METADATA-LENGTH)
                    (> (len (get execution-instructions some-req)) MIN-METADATA-LENGTH)
            )
            false
        )
    )
)

(define-private (update-compliance-status (research-id uint))
    (let (
        (publication-data (unwrap! (map-get? research-data-publications { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
        (metadata-complete (validate-metadata-completeness research-id))
        (code-available (check-reproducibility-requirements research-id))
        (compliance-score (if (and metadata-complete code-available) u100 u50))
    )
        (map-set compliance-tracking
            { research-id: research-id }
            {
                data-published: true,
                metadata-complete: metadata-complete,
                code-available: code-available,
                reproducible: false, ;; Will be set during verification
                peer-verified: false, ;; Will be set during verification
                compliance-score: compliance-score,
                last-updated: burn-block-height
            }
        )
        (ok true)
    )
)

;; Public functions
(define-public (publish-research-data
    (research-id uint)
    (title (string-ascii 200))
    (data-hash (buff 32))
    (metadata-hash (buff 32))
    (dataset-url (string-ascii 300))
    (license-type (string-ascii 50))
    (access-level (string-ascii 20))
)
    (let (
        (researcher tx-sender)
        (publication-deadline (+ burn-block-height PUBLICATION-DEADLINE))
    )
        (asserts! (is-none (map-get? research-data-publications { research-id: research-id })) ERR-DATA-ALREADY-PUBLISHED)
        (asserts! (> (len title) u10) ERR-INVALID-METADATA)
        (asserts! (> (len dataset-url) u10) ERR-INVALID-METADATA)
        
        (map-set research-data-publications
            { research-id: research-id }
            {
                researcher: researcher,
                title: title,
                publication-date: burn-block-height,
                data-hash: data-hash,
                metadata-hash: metadata-hash,
                dataset-url: dataset-url,
                license-type: license-type,
                access-level: access-level,
                compliance-status: COMPLIANCE-PENDING,
                verification-deadline: publication-deadline
            }
        )
        
        (var-set total-publications (+ (var-get total-publications) u1))
        
        (ok research-id)
    )
)

(define-public (add-data-metadata
    (research-id uint)
    (abstract (string-ascii 500))
    (methodology (string-ascii 800))
    (data-collection-period (string-ascii 100))
    (sample-size uint)
    (variables-count uint)
    (file-formats (string-ascii 200))
    (data-size uint)
    (keywords (string-ascii 300))
    (doi (optional (string-ascii 100)))
)
    (let (
        (publication-data (unwrap! (map-get? research-data-publications { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
    )
        (asserts! (is-eq tx-sender (get researcher publication-data)) ERR-NOT-AUTHORIZED)
        (asserts! (and (>= (len abstract) MIN-METADATA-LENGTH) (<= (len abstract) MAX-METADATA-LENGTH)) ERR-INVALID-METADATA)
        (asserts! (and (>= (len methodology) MIN-METADATA-LENGTH) (<= (len methodology) MAX-METADATA-LENGTH)) ERR-INVALID-METADATA)
        (asserts! (> sample-size u0) ERR-INVALID-METADATA)
        
        (map-set data-metadata
            { research-id: research-id }
            {
                abstract: abstract,
                methodology: methodology,
                data-collection-period: data-collection-period,
                sample-size: sample-size,
                variables-count: variables-count,
                file-formats: file-formats,
                data-size: data-size,
                keywords: keywords,
                doi: doi
            }
        )
        
        (try! (update-compliance-status research-id))
        
        (ok true)
    )
)

(define-public (add-reproducibility-info
    (research-id uint)
    (code-repository-url (string-ascii 300))
    (code-hash (buff 32))
    (environment-description (string-ascii 400))
    (dependencies (string-ascii 500))
    (execution-instructions (string-ascii 600))
    (expected-outputs (string-ascii 400))
    (computational-requirements (string-ascii 300))
)
    (let (
        (publication-data (unwrap! (map-get? research-data-publications { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
    )
        (asserts! (is-eq tx-sender (get researcher publication-data)) ERR-NOT-AUTHORIZED)
        (asserts! (> (len code-repository-url) u10) ERR-INVALID-METADATA)
        (asserts! (>= (len environment-description) MIN-METADATA-LENGTH) ERR-INVALID-METADATA)
        (asserts! (>= (len execution-instructions) MIN-METADATA-LENGTH) ERR-INVALID-METADATA)
        
        (map-set reproducibility-requirements
            { research-id: research-id }
            {
                code-repository-url: code-repository-url,
                code-hash: code-hash,
                environment-description: environment-description,
                dependencies: dependencies,
                execution-instructions: execution-instructions,
                expected-outputs: expected-outputs,
                computational-requirements: computational-requirements
            }
        )
        
        (try! (update-compliance-status research-id))
        
        (ok true)
    )
)

(define-public (verify-data-publication
    (research-id uint)
    (data-integrity-score uint)
    (metadata-completeness-score uint)
    (reproducibility-score uint)
    (verification-notes (string-ascii 500))
)
    (let (
        (verifier tx-sender)
        (publication-data (unwrap! (map-get? research-data-publications { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
        (overall-score (calculate-overall-score data-integrity-score metadata-completeness-score reproducibility-score))
        (verification-passed (>= overall-score REPRODUCIBILITY-SCORE-THRESHOLD))
    )
        (asserts! (is-authorized-verifier verifier) ERR-NOT-AUTHORIZED)
        (asserts! (<= burn-block-height (get verification-deadline publication-data)) ERR-DEADLINE-PASSED)
        (asserts! (and (>= data-integrity-score u1) (<= data-integrity-score u100)) ERR-INVALID-METADATA)
        (asserts! (and (>= metadata-completeness-score u1) (<= metadata-completeness-score u100)) ERR-INVALID-METADATA)
        (asserts! (and (>= reproducibility-score u1) (<= reproducibility-score u100)) ERR-INVALID-METADATA)
        (asserts! (is-none (map-get? verification-records { research-id: research-id, verifier: verifier })) ERR-ALREADY-VERIFIED)
        
        ;; Record verification
        (map-set verification-records
            { research-id: research-id, verifier: verifier }
            {
                verification-date: burn-block-height,
                data-integrity-score: data-integrity-score,
                metadata-completeness-score: metadata-completeness-score,
                reproducibility-score: reproducibility-score,
                overall-score: overall-score,
                verification-notes: verification-notes,
                passed: verification-passed
            }
        )
        
        ;; Update publication status
        (let (
            (new-status (if verification-passed COMPLIANCE-VERIFIED COMPLIANCE-FAILED))
        )
            (map-set research-data-publications
                { research-id: research-id }
                (merge publication-data {
                    compliance-status: new-status
                })
            )
            
            ;; Update compliance tracking
            (let (
                (compliance-data (default-to
                    { data-published: false, metadata-complete: false, code-available: false,
                      reproducible: false, peer-verified: false, compliance-score: u0, last-updated: u0 }
                    (map-get? compliance-tracking { research-id: research-id })
                ))
            )
                (map-set compliance-tracking
                    { research-id: research-id }
                    (merge compliance-data {
                        reproducible: (>= reproducibility-score REPRODUCIBILITY-SCORE-THRESHOLD),
                        peer-verified: verification-passed,
                        compliance-score: overall-score,
                        last-updated: burn-block-height
                    })
                )
            )
            
            ;; Update counters
            (if verification-passed
                (var-set verified-publications (+ (var-get verified-publications) u1))
                (var-set failed-publications (+ (var-get failed-publications) u1))
            )
        )
        
        (ok verification-passed)
    )
)

(define-public (log-data-access
    (research-id uint)
    (access-type (string-ascii 20))
    (purpose (string-ascii 100))
)
    (let (
        (accessor tx-sender)
        (publication-data (unwrap! (map-get? research-data-publications { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
        (access-approved (or 
            (is-eq (get access-level publication-data) "public")
            (is-eq accessor (get researcher publication-data))
        ))
    )
        (asserts! access-approved ERR-NOT-AUTHORIZED)
        
        (map-set data-access-logs
            { research-id: research-id, accessor: accessor, access-date: burn-block-height }
            {
                access-type: access-type,
                purpose: purpose,
                approved: access-approved
            }
        )
        
        (ok true)
    )
)

(define-public (add-authorized-verifier (new-verifier principal))
    (let (
        (current-verifiers (var-get authorized-verifiers))
    )
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (asserts! (is-none (index-of current-verifiers new-verifier)) ERR-ALREADY-VERIFIED)
        
        (var-set authorized-verifiers (unwrap! (as-max-len? (append current-verifiers new-verifier) u50) ERR-INVALID-METADATA))
        
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-publication-info (research-id uint))
    (map-get? research-data-publications { research-id: research-id })
)

(define-read-only (get-data-metadata (research-id uint))
    (map-get? data-metadata { research-id: research-id })
)

(define-read-only (get-reproducibility-info (research-id uint))
    (map-get? reproducibility-requirements { research-id: research-id })
)

(define-read-only (get-verification-record (research-id uint) (verifier principal))
    (map-get? verification-records { research-id: research-id, verifier: verifier })
)

(define-read-only (get-compliance-status (research-id uint))
    (map-get? compliance-tracking { research-id: research-id })
)

(define-read-only (get-access-log (research-id uint) (accessor principal) (access-date uint))
    (map-get? data-access-logs { research-id: research-id, accessor: accessor, access-date: access-date })
)

(define-read-only (is-compliant (research-id uint))
    (let (
        (compliance-data (map-get? compliance-tracking { research-id: research-id }))
    )
        (match compliance-data
            some-data (
                and
                    (get data-published some-data)
                    (get metadata-complete some-data)
                    (get code-available some-data)
                    (get peer-verified some-data)
                    (>= (get compliance-score some-data) REPRODUCIBILITY-SCORE-THRESHOLD)
            )
            false
        )
    )
)

(define-read-only (get-contract-stats)
    {
        total-publications: (var-get total-publications),
        verified-publications: (var-get verified-publications),
        failed-publications: (var-get failed-publications),
        authorized-verifiers-count: (len (var-get authorized-verifiers))
    }
)

