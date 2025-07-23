(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-vote (err u104))
(define-constant err-proposal-closed (err u105))
(define-constant err-insufficient-balance (err u106))

(define-data-var next-task-id uint u1)
(define-data-var next-waste-id uint u1)
(define-data-var next-proposal-id uint u1)
(define-data-var total-rewards-pool uint u0)

(define-map teams principal {
    name: (string-ascii 50),
    leader: principal,
    members: (list 10 principal),
    active: bool
})

(define-map lean-tasks uint {
    id: uint,
    team: principal,
    assignee: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    category: (string-ascii 20),
    status: (string-ascii 20),
    created-at: uint,
    completed-at: (optional uint),
    verified: bool,
    impact-score: uint
})

(define-map waste-events uint {
    id: uint,
    reporter: principal,
    team: principal,
    waste-type: (string-ascii 30),
    description: (string-ascii 500),
    impact-level: uint,
    timestamp: uint,
    verified: bool,
    reduction-value: uint
})

(define-map kaizen-proposals uint {
    id: uint,
    proposer: principal,
    team: principal,
    title: (string-ascii 100),
    description: (string-ascii 1000),
    implementation-cost: uint,
    expected-savings: uint,
    votes-for: uint,
    votes-against: uint,
    status: (string-ascii 20),
    created-at: uint,
    voting-deadline: uint
})

(define-map proposal-votes {proposal-id: uint, voter: principal} bool)

(define-map user-rewards principal uint)

(define-map team-metrics principal {
    tasks-completed: uint,
    waste-events-reported: uint,
    kaizen-proposals: uint,
    total-impact-score: uint,
    rewards-earned: uint
})

(define-public (register-team (name (string-ascii 50)) (members (list 10 principal)))
    (let ((team-principal tx-sender))
        (asserts! (is-none (map-get? teams team-principal)) err-already-exists)
        (map-set teams team-principal {
            name: name,
            leader: tx-sender,
            members: members,
            active: true
        })
        (map-set team-metrics team-principal {
            tasks-completed: u0,
            waste-events-reported: u0,
            kaizen-proposals: u0,
            total-impact-score: u0,
            rewards-earned: u0
        })
        (ok team-principal)
    )
)

(define-public (create-lean-task 
    (team principal)
    (assignee principal)
    (title (string-ascii 100))
    (description (string-ascii 500))
    (category (string-ascii 20))
)
    (let ((task-id (var-get next-task-id)))
        (asserts! (is-some (map-get? teams team)) err-not-found)
        (map-set lean-tasks task-id {
            id: task-id,
            team: team,
            assignee: assignee,
            title: title,
            description: description,
            category: category,
            status: "pending",
            created-at: stacks-block-height,
            completed-at: none,
            verified: false,
            impact-score: u0
        })
        (var-set next-task-id (+ task-id u1))
        (ok task-id)
    )
)

(define-public (complete-task (task-id uint) (impact-score uint))
    (let ((task (unwrap! (map-get? lean-tasks task-id) err-not-found)))
        (asserts! (is-eq (get assignee task) tx-sender) err-unauthorized)
        (asserts! (is-eq (get status task) "pending") err-invalid-vote)
        (begin
            (map-set lean-tasks task-id (merge task {
                status: "completed",
                completed-at: (some stacks-block-height),
                impact-score: impact-score
            }))
            (unwrap-panic (update-team-metrics (get team task) "task-completed" impact-score))
            (unwrap-panic (distribute-task-reward tx-sender impact-score))
            (ok true)
        )
    )
)

(define-public (verify-task (task-id uint))
    (let ((task (unwrap! (map-get? lean-tasks task-id) err-not-found)))
        (asserts! (is-team-leader tx-sender (get team task)) err-unauthorized)
        (asserts! (is-eq (get status task) "completed") err-invalid-vote)
        (begin
            (map-set lean-tasks task-id (merge task {
                verified: true
            }))
            (let ((bonus-reward (/ (get impact-score task) u2)))
                (unwrap-panic (distribute-task-reward (get assignee task) bonus-reward))
                (ok true)
            )
        )
    )
)

(define-public (report-waste-event
    (team principal)
    (waste-type (string-ascii 30))
    (description (string-ascii 500))
    (impact-level uint)
)
    (let ((waste-id (var-get next-waste-id)))
        (asserts! (is-some (map-get? teams team)) err-not-found)
        (asserts! (<= impact-level u10) err-invalid-vote)
        (map-set waste-events waste-id {
            id: waste-id,
            reporter: tx-sender,
            team: team,
            waste-type: waste-type,
            description: description,
            impact-level: impact-level,
            timestamp: stacks-block-height,
            verified: false,
            reduction-value: u0
        })
        (var-set next-waste-id (+ waste-id u1))
        (unwrap-panic (update-team-metrics team "waste-reported" impact-level))
        (unwrap-panic (distribute-task-reward tx-sender (* impact-level u10)))
        (ok waste-id)
    )
)

(define-public (verify-waste-reduction (waste-id uint) (reduction-value uint))
    (let ((waste-event (unwrap! (map-get? waste-events waste-id) err-not-found)))
        (asserts! (is-team-leader tx-sender (get team waste-event)) err-unauthorized)
        (begin
            (map-set waste-events waste-id (merge waste-event {
                verified: true,
                reduction-value: reduction-value
            }))
            (let ((bonus-reward (* reduction-value u5)))
                (unwrap-panic (distribute-task-reward (get reporter waste-event) bonus-reward))
                (ok true)
            )
        )
    )
)

(define-public (create-kaizen-proposal
    (team principal)
    (title (string-ascii 100))
    (description (string-ascii 1000))
    (implementation-cost uint)
    (expected-savings uint)
    (voting-duration uint)
)
    (let ((proposal-id (var-get next-proposal-id)))
        (asserts! (is-some (map-get? teams team)) err-not-found)
        (map-set kaizen-proposals proposal-id {
            id: proposal-id,
            proposer: tx-sender,
            team: team,
            title: title,
            description: description,
            implementation-cost: implementation-cost,
            expected-savings: expected-savings,
            votes-for: u0,
            votes-against: u0,
            status: "active",
            created-at: stacks-block-height,
            voting-deadline: (+ stacks-block-height voting-duration)
        })
        (var-set next-proposal-id (+ proposal-id u1))
        (unwrap-panic (update-team-metrics team "kaizen-proposed" u1))
        (ok proposal-id)
    )
)

(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
    (let ((proposal (unwrap! (map-get? kaizen-proposals proposal-id) err-not-found))
          (vote-key {proposal-id: proposal-id, voter: tx-sender}))
        (asserts! (is-eq (get status proposal) "active") err-proposal-closed)
        (asserts! (< stacks-block-height (get voting-deadline proposal)) err-proposal-closed)
        (asserts! (is-none (map-get? proposal-votes vote-key)) err-already-exists)
        (map-set proposal-votes vote-key vote-for)
        (if vote-for
            (map-set kaizen-proposals proposal-id (merge proposal {
                votes-for: (+ (get votes-for proposal) u1)
            }))
            (map-set kaizen-proposals proposal-id (merge proposal {
                votes-against: (+ (get votes-against proposal) u1)
            }))
        )
        (unwrap-panic (distribute-task-reward tx-sender u5))
        (ok true)
    )
)

(define-public (finalize-proposal (proposal-id uint))
    (let ((proposal (unwrap! (map-get? kaizen-proposals proposal-id) err-not-found)))
        (asserts! (>= stacks-block-height (get voting-deadline proposal)) err-proposal-closed)
        (asserts! (is-eq (get status proposal) "active") err-proposal-closed)
        (let ((approved (> (get votes-for proposal) (get votes-against proposal))))
            (begin
                (map-set kaizen-proposals proposal-id (merge proposal {
                    status: (if approved "approved" "rejected")
                }))
                (if approved
                    (unwrap-panic (distribute-task-reward (get proposer proposal) (get expected-savings proposal)))
                    true
                )
                (ok approved)
            )
        )
    )
)

(define-public (add-to-rewards-pool (amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set total-rewards-pool (+ (var-get total-rewards-pool) amount))
        (ok true)
    )
)

(define-private (distribute-task-reward (recipient principal) (amount uint))
    (let ((current-balance (default-to u0 (map-get? user-rewards recipient))))
        (map-set user-rewards recipient (+ current-balance amount))
        (ok true)
    )
)

(define-private (update-team-metrics (team principal) (metric-type (string-ascii 20)) (value uint))
    (let ((current-metrics (default-to {
            tasks-completed: u0,
            waste-events-reported: u0,
            kaizen-proposals: u0,
            total-impact-score: u0,
            rewards-earned: u0
        } (map-get? team-metrics team))))
        (begin
            (if (is-eq metric-type "task-completed")
                (map-set team-metrics team (merge current-metrics {
                    tasks-completed: (+ (get tasks-completed current-metrics) u1),
                    total-impact-score: (+ (get total-impact-score current-metrics) value)
                }))
                (if (is-eq metric-type "waste-reported")
                    (map-set team-metrics team (merge current-metrics {
                        waste-events-reported: (+ (get waste-events-reported current-metrics) u1)
                    }))
                    (map-set team-metrics team (merge current-metrics {
                        kaizen-proposals: (+ (get kaizen-proposals current-metrics) value)
                    }))
                )
            )
            (ok true)
        )
    )
)

(define-private (is-team-leader (user principal) (team principal))
    (match (map-get? teams team)
        team-data (is-eq user (get leader team-data))
        false
    )
)

(define-read-only (get-task (task-id uint))
    (map-get? lean-tasks task-id)
)

(define-read-only (get-waste-event (waste-id uint))
    (map-get? waste-events waste-id)
)

(define-read-only (get-proposal (proposal-id uint))
    (map-get? kaizen-proposals proposal-id)
)

(define-read-only (get-team-info (team principal))
    (map-get? teams team)
)

(define-read-only (get-team-metrics (team principal))
    (map-get? team-metrics team)
)

(define-read-only (get-user-rewards (user principal))
    (default-to u0 (map-get? user-rewards user))
)

(define-read-only (get-user-vote (proposal-id uint) (voter principal))
    (map-get? proposal-votes {proposal-id: proposal-id, voter: voter})
)

(define-read-only (get-total-rewards-pool)
    (var-get total-rewards-pool)
)
