(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-vote (err u104))
(define-constant err-proposal-closed (err u105))
(define-constant err-insufficient-balance (err u106))
(define-constant err-invalid-benchmark (err u107))
(define-constant err-benchmark-not-active (err u108))
(define-constant err-milestone-expired (err u109))
(define-constant err-milestone-completed (err u110))
(define-constant err-invalid-progress (err u111))

(define-data-var next-task-id uint u1)
(define-data-var next-waste-id uint u1)
(define-data-var next-proposal-id uint u1)
(define-data-var total-rewards-pool uint u0)
(define-data-var next-benchmark-id uint u1)
(define-data-var next-milestone-id uint u1)

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

(define-map performance-benchmarks uint {
    id: uint,
    team: principal,
    metric-name: (string-ascii 50),
    target-value: uint,
    measurement-unit: (string-ascii 20),
    time-period: uint,
    reward-multiplier: uint,
    active: bool,
    created-at: uint,
    expires-at: uint
})

(define-map performance-records uint {
    id: uint,
    benchmark-id: uint,
    team: principal,
    actual-value: uint,
    achievement-rate: uint,
    recorded-at: uint,
    verified: bool,
    rewards-earned: uint
})

(define-map benchmark-achievements {team: principal, benchmark-id: uint} {
    total-records: uint,
    average-achievement: uint,
    best-performance: uint,
    last-updated: uint
})

(define-map project-milestones uint {
    id: uint,
    team: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    deadline: uint,
    base-reward: uint,
    early-bonus-multiplier: uint,
    late-penalty-multiplier: uint,
    progress-percentage: uint,
    status: (string-ascii 20),
    created-at: uint,
    completed-at: (optional uint),
    final-reward: uint
})

(define-map milestone-progress-updates uint {
    update-id: uint,
    milestone-id: uint,
    team: principal,
    progress-percentage: uint,
    update-note: (string-ascii 300),
    updated-by: principal,
    updated-at: uint
})

(define-map team-milestone-stats principal {
    total-milestones: uint,
    completed-on-time: uint,
    completed-early: uint,
    completed-late: uint,
    total-rewards-earned: uint,
    average-completion-time: uint
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

(define-public (create-performance-benchmark
    (team principal)
    (metric-name (string-ascii 50))
    (target-value uint)
    (measurement-unit (string-ascii 20))
    (time-period uint)
    (reward-multiplier uint)
)
    (let ((benchmark-id (var-get next-benchmark-id)))
        (asserts! (is-some (map-get? teams team)) err-not-found)
        (asserts! (is-team-leader tx-sender team) err-unauthorized)
        (asserts! (> target-value u0) err-invalid-benchmark)
        (asserts! (> reward-multiplier u0) err-invalid-benchmark)
        (asserts! (> time-period u0) err-invalid-benchmark)
        (map-set performance-benchmarks benchmark-id {
            id: benchmark-id,
            team: team,
            metric-name: metric-name,
            target-value: target-value,
            measurement-unit: measurement-unit,
            time-period: time-period,
            reward-multiplier: reward-multiplier,
            active: true,
            created-at: stacks-block-height,
            expires-at: (+ stacks-block-height time-period)
        })
        (var-set next-benchmark-id (+ benchmark-id u1))
        (ok benchmark-id)
    )
)

(define-public (record-performance
    (benchmark-id uint)
    (actual-value uint)
)
    (let ((benchmark (unwrap! (map-get? performance-benchmarks benchmark-id) err-not-found))
          (record-id stacks-block-height))
        (asserts! (get active benchmark) err-benchmark-not-active)
        (asserts! (< stacks-block-height (get expires-at benchmark)) err-benchmark-not-active)
        (asserts! (is-some (map-get? teams (get team benchmark))) err-not-found)
        (let ((achievement-rate (calculate-achievement-rate (get target-value benchmark) actual-value))
              (reward-amount (* achievement-rate (get reward-multiplier benchmark))))
            (map-set performance-records record-id {
                id: record-id,
                benchmark-id: benchmark-id,
                team: (get team benchmark),
                actual-value: actual-value,
                achievement-rate: achievement-rate,
                recorded-at: stacks-block-height,
                verified: false,
                rewards-earned: u0
            })
            (unwrap-panic (update-benchmark-achievements (get team benchmark) benchmark-id achievement-rate actual-value))
            (ok record-id)
        )
    )
)

(define-public (verify-performance-record (record-id uint))
    (let ((record (unwrap! (map-get? performance-records record-id) err-not-found))
          (benchmark (unwrap! (map-get? performance-benchmarks (get benchmark-id record)) err-not-found)))
        (asserts! (is-team-leader tx-sender (get team record)) err-unauthorized)
        (asserts! (not (get verified record)) err-already-exists)
        (let ((reward-amount (* (get achievement-rate record) (get reward-multiplier benchmark))))
            (map-set performance-records record-id (merge record {
                verified: true,
                rewards-earned: reward-amount
            }))
            (unwrap-panic (distribute-task-reward (get team record) reward-amount))
            (ok true)
        )
    )
)

(define-public (deactivate-benchmark (benchmark-id uint))
    (let ((benchmark (unwrap! (map-get? performance-benchmarks benchmark-id) err-not-found)))
        (asserts! (is-team-leader tx-sender (get team benchmark)) err-unauthorized)
        (map-set performance-benchmarks benchmark-id (merge benchmark {
            active: false
        }))
        (ok true)
    )
)

(define-private (calculate-achievement-rate (target-value uint) (actual-value uint))
    (if (<= target-value actual-value)
        (/ (* actual-value u100) target-value)
        (/ (* target-value u100) actual-value)
    )
)

(define-private (update-benchmark-achievements (team principal) (benchmark-id uint) (achievement-rate uint) (performance-value uint))
    (let ((achievement-key {team: team, benchmark-id: benchmark-id})
          (current-data (default-to {
              total-records: u0,
              average-achievement: u0,
              best-performance: u0,
              last-updated: u0
          } (map-get? benchmark-achievements achievement-key))))
        (let ((new-total (+ (get total-records current-data) u1))
              (new-average (/ (+ (* (get average-achievement current-data) (get total-records current-data)) achievement-rate) new-total))
              (new-best (if (> performance-value (get best-performance current-data)) performance-value (get best-performance current-data))))
            (map-set benchmark-achievements achievement-key {
                total-records: new-total,
                average-achievement: new-average,
                best-performance: new-best,
                last-updated: stacks-block-height
            })
            (ok true)
        )
    )
)

(define-read-only (get-benchmark (benchmark-id uint))
    (map-get? performance-benchmarks benchmark-id)
)

(define-read-only (get-performance-record (record-id uint))
    (map-get? performance-records record-id)
)

(define-read-only (get-team-benchmark-achievements (team principal) (benchmark-id uint))
    (map-get? benchmark-achievements {team: team, benchmark-id: benchmark-id})
)

(define-read-only (get-active-benchmarks-for-team (team principal))
    (ok "Use get-benchmark with sequential IDs to find active benchmarks")
)

(define-public (create-project-milestone
    (team principal)
    (title (string-ascii 100))
    (description (string-ascii 500))
    (deadline uint)
    (base-reward uint)
    (early-bonus-multiplier uint)
    (late-penalty-multiplier uint)
)
    (let ((milestone-id (var-get next-milestone-id)))
        (asserts! (is-some (map-get? teams team)) err-not-found)
        (asserts! (is-team-leader tx-sender team) err-unauthorized)
        (asserts! (> deadline stacks-block-height) err-milestone-expired)
        (asserts! (> base-reward u0) err-invalid-progress)
        (map-set project-milestones milestone-id {
            id: milestone-id,
            team: team,
            title: title,
            description: description,
            deadline: deadline,
            base-reward: base-reward,
            early-bonus-multiplier: early-bonus-multiplier,
            late-penalty-multiplier: late-penalty-multiplier,
            progress-percentage: u0,
            status: "active",
            created-at: stacks-block-height,
            completed-at: none,
            final-reward: u0
        })
        (var-set next-milestone-id (+ milestone-id u1))
        (unwrap-panic (initialize-team-milestone-stats team))
        (ok milestone-id)
    )
)

(define-public (update-milestone-progress
    (milestone-id uint)
    (progress-percentage uint)
    (update-note (string-ascii 300))
)
    (let ((milestone (unwrap! (map-get? project-milestones milestone-id) err-not-found))
          (update-id stacks-block-height))
        (asserts! (is-eq (get status milestone) "active") err-milestone-completed)
        (asserts! (<= progress-percentage u100) err-invalid-progress)
        (asserts! (< stacks-block-height (get deadline milestone)) err-milestone-expired)
        (map-set milestone-progress-updates update-id {
            update-id: update-id,
            milestone-id: milestone-id,
            team: (get team milestone),
            progress-percentage: progress-percentage,
            update-note: update-note,
            updated-by: tx-sender,
            updated-at: stacks-block-height
        })
        (map-set project-milestones milestone-id (merge milestone {
            progress-percentage: progress-percentage
        }))
        (ok update-id)
    )
)

(define-public (complete-milestone (milestone-id uint))
    (let ((milestone (unwrap! (map-get? project-milestones milestone-id) err-not-found)))
        (asserts! (is-eq (get status milestone) "active") err-milestone-completed)
        (asserts! (is-team-leader tx-sender (get team milestone)) err-unauthorized)
        (let ((completion-time stacks-block-height)
              (deadline (get deadline milestone))
              (base-reward (get base-reward milestone))
              (final-reward (calculate-milestone-reward milestone completion-time)))
            (map-set project-milestones milestone-id (merge milestone {
                status: "completed",
                completed-at: (some completion-time),
                progress-percentage: u100,
                final-reward: final-reward
            }))
            (unwrap-panic (distribute-task-reward (get team milestone) final-reward))
            (unwrap-panic (update-team-milestone-stats (get team milestone) milestone completion-time))
            (ok final-reward)
        )
    )
)

(define-public (mark-milestone-at-risk (milestone-id uint))
    (let ((milestone (unwrap! (map-get? project-milestones milestone-id) err-not-found)))
        (asserts! (is-team-leader tx-sender (get team milestone)) err-unauthorized)
        (asserts! (is-eq (get status milestone) "active") err-milestone-completed)
        (map-set project-milestones milestone-id (merge milestone {
            status: "at-risk"
        }))
        (ok true)
    )
)

(define-private (calculate-milestone-reward (milestone {id: uint, team: principal, title: (string-ascii 100), description: (string-ascii 500), deadline: uint, base-reward: uint, early-bonus-multiplier: uint, late-penalty-multiplier: uint, progress-percentage: uint, status: (string-ascii 20), created-at: uint, completed-at: (optional uint), final-reward: uint}) (completion-time uint))
    (let ((deadline (get deadline milestone))
          (base-reward (get base-reward milestone)))
        (if (< completion-time deadline)
            (let ((days-early (- deadline completion-time))
                  (bonus (* base-reward (get early-bonus-multiplier milestone))))
                (+ base-reward (/ (* bonus days-early) u100))
            )
            (if (> completion-time deadline)
                (let ((days-late (- completion-time deadline))
                      (penalty (* base-reward (get late-penalty-multiplier milestone))))
                    (if (> base-reward (/ (* penalty days-late) u100))
                        (- base-reward (/ (* penalty days-late) u100))
                        u1
                    )
                )
                base-reward
            )
        )
    )
)

(define-private (initialize-team-milestone-stats (team principal))
    (begin
        (if (is-none (map-get? team-milestone-stats team))
            (map-set team-milestone-stats team {
                total-milestones: u1,
                completed-on-time: u0,
                completed-early: u0,
                completed-late: u0,
                total-rewards-earned: u0,
                average-completion-time: u0
            })
            (let ((current-stats (unwrap-panic (map-get? team-milestone-stats team))))
                (map-set team-milestone-stats team (merge current-stats {
                    total-milestones: (+ (get total-milestones current-stats) u1)
                }))
            )
        )
        (ok true)
    )
)

(define-private (update-team-milestone-stats (team principal) (milestone {id: uint, team: principal, title: (string-ascii 100), description: (string-ascii 500), deadline: uint, base-reward: uint, early-bonus-multiplier: uint, late-penalty-multiplier: uint, progress-percentage: uint, status: (string-ascii 20), created-at: uint, completed-at: (optional uint), final-reward: uint}) (completion-time uint))
    (let ((current-stats (default-to {
            total-milestones: u0,
            completed-on-time: u0,
            completed-early: u0,
            completed-late: u0,
            total-rewards-earned: u0,
            average-completion-time: u0
        } (map-get? team-milestone-stats team)))
          (deadline (get deadline milestone))
          (final-reward (get final-reward milestone)))
        (let ((new-stats 
               (if (< completion-time deadline)
                   (merge current-stats {
                       completed-early: (+ (get completed-early current-stats) u1),
                       total-rewards-earned: (+ (get total-rewards-earned current-stats) final-reward)
                   })
                   (if (> completion-time deadline)
                       (merge current-stats {
                           completed-late: (+ (get completed-late current-stats) u1),
                           total-rewards-earned: (+ (get total-rewards-earned current-stats) final-reward)
                       })
                       (merge current-stats {
                           completed-on-time: (+ (get completed-on-time current-stats) u1),
                           total-rewards-earned: (+ (get total-rewards-earned current-stats) final-reward)
                       })
                   )
               )))
            (map-set team-milestone-stats team new-stats)
            (ok true)
        )
    )
)

(define-read-only (get-milestone (milestone-id uint))
    (map-get? project-milestones milestone-id)
)

(define-read-only (get-milestone-progress-update (update-id uint))
    (map-get? milestone-progress-updates update-id)
)

(define-read-only (get-team-milestone-stats (team principal))
    (map-get? team-milestone-stats team)
)

(define-read-only (assess-milestone-risk (milestone-id uint))
    (match (map-get? project-milestones milestone-id)
        milestone (let ((time-remaining (- (get deadline milestone) stacks-block-height))
                        (progress (get progress-percentage milestone)))
                    (if (and (< time-remaining u50) (< progress u75))
                        "high-risk"
                        (if (and (< time-remaining u100) (< progress u50))
                            "medium-risk"
                            "low-risk"
                        )
                    )
                )
        "milestone-not-found"
    )
)
