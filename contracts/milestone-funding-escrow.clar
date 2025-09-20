;; milestone-funding-escrow
;; Milestone-based research funding with automated releases based on deliverable completion

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-PROJECT-NOT-FOUND (err u201))
(define-constant ERR-MILESTONE-NOT-FOUND (err u202))
(define-constant ERR-INSUFFICIENT-FUNDS (err u203))
(define-constant ERR-MILESTONE-COMPLETED (err u204))
(define-constant ERR-MILESTONE-NOT-READY (err u205))
(define-constant ERR-INVALID-MILESTONE (err u206))
(define-constant ERR-PROJECT-COMPLETED (err u207))
(define-constant ERR-DEADLINE-PASSED (err u208))
(define-constant ERR-INVALID-AMOUNT (err u209))
(define-constant ERR-ALREADY-FUNDED (err u210))

;; Constants
(define-constant MIN-FUNDING-AMOUNT u1000000) ;; 1 STX minimum
(define-constant MAX-MILESTONES u20)
(define-constant DISPUTE-PERIOD u1008) ;; ~1 week in blocks
(define-constant PLATFORM-FEE-RATE u50) ;; 0.5% platform fee (50 basis points)
(define-constant BASIS-POINTS u10000)

;; Data structures
(define-map research-projects
    { project-id: uint }
    {
        researcher: principal,
        title: (string-ascii 200),
        description: (string-ascii 500),
        total-funding: uint,
        funding-raised: uint,
        milestones-count: uint,
        completed-milestones: uint,
        status: (string-ascii 20), ;; active, completed, cancelled, disputed
        created-block: uint,
        completion-deadline: uint
    }
)

(define-map project-milestones
    { project-id: uint, milestone-id: uint }
    {
        title: (string-ascii 100),
        description: (string-ascii 300),
        funding-amount: uint,
        completion-criteria: (string-ascii 200),
        estimated-completion: uint,
        status: (string-ascii 20), ;; pending, in-progress, submitted, approved, rejected
        deliverable-hash: (optional (buff 32)),
        completion-block: (optional uint),
        reviewer: (optional principal)
    }
)

(define-map project-funding
    { project-id: uint, funder: principal }
    {
        amount: uint,
        funded-block: uint,
        refunded: bool,
        refund-amount: uint
    }
)

(define-map milestone-approvals
    { project-id: uint, milestone-id: uint }
    {
        approver: principal,
        approved: bool,
        approval-block: uint,
        comments-hash: (optional (buff 32))
    }
)

(define-map escrow-balances
    { project-id: uint }
    {
        total-escrowed: uint,
        released: uint,
        pending-release: uint,
        platform-fees: uint
    }
)

;; Variables
(define-data-var next-project-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var total-projects uint u0)
(define-data-var total-funding-locked uint u0)
(define-data-var platform-fee-collector principal tx-sender)

;; Private functions
(define-private (calculate-platform-fee (amount uint))
    (/ (* amount PLATFORM-FEE-RATE) BASIS-POINTS)
)

(define-private (validate-milestone-order (project-id uint) (milestone-id uint))
    (let (
        (project-data (unwrap! (map-get? research-projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    )
        (if (is-eq milestone-id u1)
            (ok true)
            (let (
                (prev-milestone (unwrap! (map-get? project-milestones { project-id: project-id, milestone-id: (- milestone-id u1) }) ERR-MILESTONE-NOT-FOUND))
            )
                (ok (is-eq (get status prev-milestone) "approved"))
            )
        )
    )
)

(define-private (release-milestone-funds (project-id uint) (milestone-id uint))
    (let (
        (milestone-data (unwrap! (map-get? project-milestones { project-id: project-id, milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND))
        (project-data (unwrap! (map-get? research-projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
        (escrow-data (unwrap! (map-get? escrow-balances { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
        (funding-amount (get funding-amount milestone-data))
        (platform-fee (calculate-platform-fee funding-amount))
        (net-amount (- funding-amount platform-fee))
    )
        (asserts! (>= (get total-escrowed escrow-data) funding-amount) ERR-INSUFFICIENT-FUNDS)
        
        ;; Transfer funds to researcher
        (try! (stx-transfer? net-amount (as-contract tx-sender) (get researcher project-data)))
        
        ;; Transfer platform fee
        (try! (stx-transfer? platform-fee (as-contract tx-sender) (var-get platform-fee-collector)))
        
        ;; Update escrow balance
        (map-set escrow-balances
            { project-id: project-id }
            (merge escrow-data {
                released: (+ (get released escrow-data) funding-amount),
                platform-fees: (+ (get platform-fees escrow-data) platform-fee)
            })
        )
        
        ;; Update milestone status
        (map-set project-milestones
            { project-id: project-id, milestone-id: milestone-id }
            (merge milestone-data {
                status: "approved",
                completion-block: (some burn-block-height)
            })
        )
        
        ;; Update project completed milestones
        (map-set research-projects
            { project-id: project-id }
            (merge project-data {
                completed-milestones: (+ (get completed-milestones project-data) u1)
            })
        )
        
        (ok true)
    )
)

;; Public functions
(define-public (create-research-project
    (title (string-ascii 200))
    (description (string-ascii 500))
    (total-funding uint)
    (completion-deadline uint)
)
    (let (
        (project-id (var-get next-project-id))
        (researcher tx-sender)
    )
        (asserts! (>= total-funding MIN-FUNDING-AMOUNT) ERR-INVALID-AMOUNT)
        (asserts! (> completion-deadline burn-block-height) ERR-DEADLINE-PASSED)
        
        (map-set research-projects
            { project-id: project-id }
            {
                researcher: researcher,
                title: title,
                description: description,
                total-funding: total-funding,
                funding-raised: u0,
                milestones-count: u0,
                completed-milestones: u0,
                status: "active",
                created-block: burn-block-height,
                completion-deadline: completion-deadline
            }
        )
        
        (map-set escrow-balances
            { project-id: project-id }
            {
                total-escrowed: u0,
                released: u0,
                pending-release: u0,
                platform-fees: u0
            }
        )
        
        (var-set next-project-id (+ project-id u1))
        (var-set total-projects (+ (var-get total-projects) u1))
        
        (ok project-id)
    )
)

(define-public (add-milestone
    (project-id uint)
    (title (string-ascii 100))
    (description (string-ascii 300))
    (funding-amount uint)
    (completion-criteria (string-ascii 200))
    (estimated-completion uint)
)
    (let (
        (project-data (unwrap! (map-get? research-projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
        (milestone-id (+ (get milestones-count project-data) u1))
    )
        (asserts! (is-eq tx-sender (get researcher project-data)) ERR-NOT-AUTHORIZED)
        (asserts! (< (get milestones-count project-data) MAX-MILESTONES) ERR-INVALID-MILESTONE)
        (asserts! (> funding-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> estimated-completion burn-block-height) ERR-DEADLINE-PASSED)
        
        (map-set project-milestones
            { project-id: project-id, milestone-id: milestone-id }
            {
                title: title,
                description: description,
                funding-amount: funding-amount,
                completion-criteria: completion-criteria,
                estimated-completion: estimated-completion,
                status: "pending",
                deliverable-hash: none,
                completion-block: none,
                reviewer: none
            }
        )
        
        (map-set research-projects
            { project-id: project-id }
            (merge project-data {
                milestones-count: milestone-id
            })
        )
        
        (ok milestone-id)
    )
)

(define-public (fund-project (project-id uint) (amount uint))
    (let (
        (project-data (unwrap! (map-get? research-projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
        (funder tx-sender)
        (current-funding (default-to
            { amount: u0, funded-block: u0, refunded: false, refund-amount: u0 }
            (map-get? project-funding { project-id: project-id, funder: funder })
        ))
        (escrow-data (unwrap! (map-get? escrow-balances { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
    )
        (asserts! (is-eq (get status project-data) "active") ERR-PROJECT-COMPLETED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (<= burn-block-height (get completion-deadline project-data)) ERR-DEADLINE-PASSED)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount funder (as-contract tx-sender)))
        
        ;; Update funding records
        (map-set project-funding
            { project-id: project-id, funder: funder }
            {
                amount: (+ (get amount current-funding) amount),
                funded-block: burn-block-height,
                refunded: false,
                refund-amount: u0
            }
        )
        
        ;; Update project funding
        (map-set research-projects
            { project-id: project-id }
            (merge project-data {
                funding-raised: (+ (get funding-raised project-data) amount)
            })
        )
        
        ;; Update escrow balance
        (map-set escrow-balances
            { project-id: project-id }
            (merge escrow-data {
                total-escrowed: (+ (get total-escrowed escrow-data) amount)
            })
        )
        
        (var-set total-funding-locked (+ (var-get total-funding-locked) amount))
        
        (ok true)
    )
)

(define-public (submit-milestone-deliverable
    (project-id uint)
    (milestone-id uint)
    (deliverable-hash (buff 32))
)
    (let (
        (project-data (unwrap! (map-get? research-projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND))
        (milestone-data (unwrap! (map-get? project-milestones { project-id: project-id, milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND))
    )
        (asserts! (is-eq tx-sender (get researcher project-data)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status milestone-data) "pending") ERR-MILESTONE-COMPLETED)
        (try! (validate-milestone-order project-id milestone-id))
        
        (map-set project-milestones
            { project-id: project-id, milestone-id: milestone-id }
            (merge milestone-data {
                status: "submitted",
                deliverable-hash: (some deliverable-hash)
            })
        )
        
        (ok true)
    )
)

(define-public (approve-milestone
    (project-id uint)
    (milestone-id uint)
    (comments-hash (optional (buff 32)))
)
    (let (
        (milestone-data (unwrap! (map-get? project-milestones { project-id: project-id, milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND))
        (approver tx-sender)
    )
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status milestone-data) "submitted") ERR-MILESTONE-NOT-READY)
        
        ;; Record approval
        (map-set milestone-approvals
            { project-id: project-id, milestone-id: milestone-id }
            {
                approver: approver,
                approved: true,
                approval-block: burn-block-height,
                comments-hash: comments-hash
            }
        )
        
        ;; Release funds
        (try! (release-milestone-funds project-id milestone-id))
        
        (ok true)
    )
)

(define-public (reject-milestone
    (project-id uint)
    (milestone-id uint)
    (comments-hash (buff 32))
)
    (let (
        (milestone-data (unwrap! (map-get? project-milestones { project-id: project-id, milestone-id: milestone-id }) ERR-MILESTONE-NOT-FOUND))
        (approver tx-sender)
    )
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status milestone-data) "submitted") ERR-MILESTONE-NOT-READY)
        
        ;; Record rejection
        (map-set milestone-approvals
            { project-id: project-id, milestone-id: milestone-id }
            {
                approver: approver,
                approved: false,
                approval-block: burn-block-height,
                comments-hash: (some comments-hash)
            }
        )
        
        ;; Reset milestone to pending for resubmission
        (map-set project-milestones
            { project-id: project-id, milestone-id: milestone-id }
            (merge milestone-data {
                status: "pending",
                deliverable-hash: none
            })
        )
        
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-project-info (project-id uint))
    (map-get? research-projects { project-id: project-id })
)

(define-read-only (get-milestone-info (project-id uint) (milestone-id uint))
    (map-get? project-milestones { project-id: project-id, milestone-id: milestone-id })
)

(define-read-only (get-funding-info (project-id uint) (funder principal))
    (map-get? project-funding { project-id: project-id, funder: funder })
)

(define-read-only (get-escrow-balance (project-id uint))
    (map-get? escrow-balances { project-id: project-id })
)

(define-read-only (get-milestone-approval (project-id uint) (milestone-id uint))
    (map-get? milestone-approvals { project-id: project-id, milestone-id: milestone-id })
)

(define-read-only (get-contract-stats)
    {
        total-projects: (var-get total-projects),
        total-funding-locked: (var-get total-funding-locked),
        next-project-id: (var-get next-project-id)
    }
)

