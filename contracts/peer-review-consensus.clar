;; peer-review-consensus
;; Decentralized peer review system with reputation-weighted scientist voting and bias prevention

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-SCIENTIST (err u101))
(define-constant ERR-ALREADY-REVIEWED (err u102))
(define-constant ERR-INVALID-RESEARCH (err u103))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u104))
(define-constant ERR-REVIEW-CLOSED (err u105))
(define-constant ERR-INVALID-SCORE (err u106))
(define-constant ERR-ALREADY-REGISTERED (err u107))
(define-constant ERR-REVIEW-NOT-FOUND (err u108))
(define-constant ERR-RESEARCH-NOT-FOUND (err u109))

;; Constants
(define-constant MIN-REPUTATION u50)
(define-constant MAX-REVIEWERS u10)
(define-constant REVIEW-DEADLINE u144) ;; ~1 day in blocks
(define-constant MIN-CONSENSUS u60) ;; 60% consensus required
(define-constant REPUTATION-REWARD u10)
(define-constant REPUTATION-PENALTY u5)

;; Data structures
(define-map scientists
    { scientist: principal }
    {
        reputation: uint,
        total-reviews: uint,
        successful-reviews: uint,
        specialization: (string-ascii 50),
        active: bool
    }
)

(define-map research-submissions
    { research-id: uint }
    {
        submitter: principal,
        title: (string-ascii 200),
        field: (string-ascii 50),
        submission-block: uint,
        status: (string-ascii 20), ;; pending, under-review, approved, rejected
        required-reviewers: uint,
        assigned-reviewers: uint,
        approval-score: uint,
        review-deadline: uint
    }
)

(define-map review-assignments
    { research-id: uint, reviewer: principal }
    {
        assigned-block: uint,
        status: (string-ascii 20), ;; assigned, completed, expired
        expertise-match: uint ;; 1-10 scale
    }
)

(define-map peer-reviews
    { research-id: uint, reviewer: principal }
    {
        score: uint, ;; 1-100 scale
        comments-hash: (buff 32),
        review-block: uint,
        weight: uint,
        anonymous: bool
    }
)

(define-map research-consensus
    { research-id: uint }
    {
        total-reviews: uint,
        weighted-score: uint,
        consensus-reached: bool,
        final-decision: (string-ascii 20)
    }
)

;; Variables
(define-data-var next-research-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var total-scientists uint u0)
(define-data-var active-research uint u0)

;; Private functions
(define-private (is-valid-score (score uint))
    (and (>= score u1) (<= score u100))
)

(define-private (calculate-weighted-score (score uint) (reputation uint))
    (/ (* score reputation) u100)
)

(define-private (update-scientist-reputation (scientist principal) (reward bool))
    (let (
        (current-data (unwrap! (map-get? scientists { scientist: scientist }) ERR-INVALID-SCIENTIST))
        (reputation-change (if reward REPUTATION-REWARD REPUTATION-PENALTY))
        (new-reputation (if reward 
            (+ (get reputation current-data) reputation-change)
            (if (> (get reputation current-data) reputation-change)
                (- (get reputation current-data) reputation-change)
                u0
            )
        ))
    )
        (ok (map-set scientists
            { scientist: scientist }
            (merge current-data {
                reputation: new-reputation,
                total-reviews: (+ (get total-reviews current-data) u1),
                successful-reviews: (if reward 
                    (+ (get successful-reviews current-data) u1)
                    (get successful-reviews current-data)
                )
            })
        ))
    )
)

(define-private (check-consensus (research-id uint))
    (let (
        (research-data (unwrap! (map-get? research-submissions { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
        (consensus-data (default-to
            { total-reviews: u0, weighted-score: u0, consensus-reached: false, final-decision: "pending" }
            (map-get? research-consensus { research-id: research-id })
        ))
        (required-reviews (get required-reviewers research-data))
        (current-reviews (get total-reviews consensus-data))
    )
        (if (>= current-reviews required-reviews)
            (let (
                (average-score (/ (get weighted-score consensus-data) current-reviews))
                (decision (if (>= average-score MIN-CONSENSUS) "approved" "rejected"))
            )
                (map-set research-consensus
                    { research-id: research-id }
                    (merge consensus-data {
                        consensus-reached: true,
                        final-decision: decision
                    })
                )
                (map-set research-submissions
                    { research-id: research-id }
                    (merge research-data { status: decision })
                )
                (ok true)
            )
            (ok false)
        )
    )
)

;; Public functions
(define-public (register-scientist (specialization (string-ascii 50)))
    (let (
        (scientist tx-sender)
    )
        (asserts! (is-none (map-get? scientists { scientist: scientist })) ERR-ALREADY-REGISTERED)
        (map-set scientists
            { scientist: scientist }
            {
                reputation: u100, ;; Starting reputation
                total-reviews: u0,
                successful-reviews: u0,
                specialization: specialization,
                active: true
            }
        )
        (var-set total-scientists (+ (var-get total-scientists) u1))
        (ok scientist)
    )
)

(define-public (submit-research 
    (title (string-ascii 200))
    (field (string-ascii 50))
    (required-reviewers uint)
)
    (let (
        (research-id (var-get next-research-id))
        (submitter tx-sender)
    )
        (asserts! (and (> required-reviewers u0) (<= required-reviewers MAX-REVIEWERS)) ERR-INVALID-RESEARCH)
        (map-set research-submissions
            { research-id: research-id }
            {
                submitter: submitter,
                title: title,
                field: field,
                submission-block: burn-block-height,
                status: "pending",
                required-reviewers: required-reviewers,
                assigned-reviewers: u0,
                approval-score: u0,
                review-deadline: (+ burn-block-height REVIEW-DEADLINE)
            }
        )
        (var-set next-research-id (+ research-id u1))
        (var-set active-research (+ (var-get active-research) u1))
        (ok research-id)
    )
)

(define-public (assign-reviewer (research-id uint) (reviewer principal) (expertise-match uint))
    (let (
        (research-data (unwrap! (map-get? research-submissions { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
        (reviewer-data (unwrap! (map-get? scientists { scientist: reviewer }) ERR-INVALID-SCIENTIST))
    )
        (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
        (asserts! (get active reviewer-data) ERR-INVALID-SCIENTIST)
        (asserts! (>= (get reputation reviewer-data) MIN-REPUTATION) ERR-INSUFFICIENT-REPUTATION)
        (asserts! (< (get assigned-reviewers research-data) (get required-reviewers research-data)) ERR-REVIEW-CLOSED)
        (asserts! (and (>= expertise-match u1) (<= expertise-match u10)) ERR-INVALID-SCORE)
        (asserts! (is-none (map-get? review-assignments { research-id: research-id, reviewer: reviewer })) ERR-ALREADY-REVIEWED)
        
        (map-set review-assignments
            { research-id: research-id, reviewer: reviewer }
            {
                assigned-block: burn-block-height,
                status: "assigned",
                expertise-match: expertise-match
            }
        )
        (map-set research-submissions
            { research-id: research-id }
            (merge research-data {
                assigned-reviewers: (+ (get assigned-reviewers research-data) u1),
                status: "under-review"
            })
        )
        (ok true)
    )
)

(define-public (submit-review 
    (research-id uint)
    (score uint)
    (comments-hash (buff 32))
    (anonymous bool)
)
    (let (
        (reviewer tx-sender)
        (research-data (unwrap! (map-get? research-submissions { research-id: research-id }) ERR-RESEARCH-NOT-FOUND))
        (reviewer-data (unwrap! (map-get? scientists { scientist: reviewer }) ERR-INVALID-SCIENTIST))
        (assignment-data (unwrap! (map-get? review-assignments { research-id: research-id, reviewer: reviewer }) ERR-NOT-AUTHORIZED))
        (review-weight (calculate-weighted-score score (get reputation reviewer-data)))
    )
        (asserts! (is-valid-score score) ERR-INVALID-SCORE)
        (asserts! (<= burn-block-height (get review-deadline research-data)) ERR-REVIEW-CLOSED)
        (asserts! (is-eq (get status assignment-data) "assigned") ERR-ALREADY-REVIEWED)
        (asserts! (is-none (map-get? peer-reviews { research-id: research-id, reviewer: reviewer })) ERR-ALREADY-REVIEWED)
        
        ;; Submit the review
        (map-set peer-reviews
            { research-id: research-id, reviewer: reviewer }
            {
                score: score,
                comments-hash: comments-hash,
                review-block: burn-block-height,
                weight: review-weight,
                anonymous: anonymous
            }
        )
        
        ;; Update assignment status
        (map-set review-assignments
            { research-id: research-id, reviewer: reviewer }
            (merge assignment-data { status: "completed" })
        )
        
        ;; Update consensus tracking
        (let (
            (current-consensus (default-to
                { total-reviews: u0, weighted-score: u0, consensus-reached: false, final-decision: "pending" }
                (map-get? research-consensus { research-id: research-id })
            ))
        )
            (map-set research-consensus
                { research-id: research-id }
                {
                    total-reviews: (+ (get total-reviews current-consensus) u1),
                    weighted-score: (+ (get weighted-score current-consensus) review-weight),
                    consensus-reached: (get consensus-reached current-consensus),
                    final-decision: (get final-decision current-consensus)
                }
            )
        )
        
        ;; Check if consensus is reached
        (try! (check-consensus research-id))
        
        ;; Reward reviewer reputation
        (try! (update-scientist-reputation reviewer true))
        
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-scientist-info (scientist principal))
    (map-get? scientists { scientist: scientist })
)

(define-read-only (get-research-info (research-id uint))
    (map-get? research-submissions { research-id: research-id })
)

(define-read-only (get-review-info (research-id uint) (reviewer principal))
    (map-get? peer-reviews { research-id: research-id, reviewer: reviewer })
)

(define-read-only (get-consensus-info (research-id uint))
    (map-get? research-consensus { research-id: research-id })
)

(define-read-only (get-contract-stats)
    {
        total-scientists: (var-get total-scientists),
        active-research: (var-get active-research),
        next-research-id: (var-get next-research-id)
    }
)

