(define-data-var contract-owner principal tx-sender)
(define-data-var next-task-id uint u0)
(define-data-var max-wip-per-member uint u3)

(define-map team-members principal bool)
(define-map tasks uint {
  creator: principal,
  assignee: (optional principal),
  title: (string-ascii 256),
  description: (string-ascii 1024),
  priority: uint,
  status: uint,
  created-at: uint,
  updated-at: uint
})
(define-map member-wip principal uint)
(define-map task-feedback uint (list 10 { reviewer: principal, feedback: (string-ascii 512), rating: uint }))
(define-map task-dependencies uint (list 10 uint))

(define-public (register-member)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err u100))
    (map-set team-members tx-sender true)
    (ok true)
  )
)

(define-public (add-member (member principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err u101))
    (map-set team-members member true)
    (ok true)
  )
)

(define-public (create-task (title (string-ascii 256)) (description (string-ascii 1024)) (priority uint) (dependencies (list 10 uint)))
  (let ((task-id (var-get next-task-id)))
    (begin
      (asserts! (is-some (map-get? team-members tx-sender)) (err u102))
      (map-set tasks task-id {
        creator: tx-sender,
        assignee: none,
        title: title,
        description: description,
        priority: priority,
        status: u0,
        created-at: block-height,
        updated-at: block-height
      })
      (map-set task-dependencies task-id dependencies)
      (var-set next-task-id (+ task-id u1))
      (ok task-id)
    )
  )
)

(define-public (assign-task (task-id uint) (assignee principal))
  (let ((task (unwrap! (map-get? tasks task-id) (err u103)))
        (current-wip (default-to u0 (map-get? member-wip assignee))))
    (begin
      (asserts! (is-eq (get creator task) tx-sender) (err u104))
      (asserts! (is-some (map-get? team-members assignee)) (err u105))
      (asserts! (< current-wip (var-get max-wip-per-member)) (err u106))
      (map-set tasks task-id (merge task { assignee: (some assignee), updated-at: block-height }))
      (map-set member-wip assignee (+ current-wip u1))
      (ok true)
    )
  )
)

(define-private (are-dependencies-completed (deps (list 10 uint)))
  (is-eq (len (filter (lambda (dep-id) (let ((dep-task (unwrap-panic (map-get? tasks dep-id)))) (not (is-eq (get status dep-task) u2)))) deps)) u0)
)

(define-public (update-task-status (task-id uint) (new-status uint))
  (let ((task (unwrap! (map-get? tasks task-id) (err u107)))
        (assignee (unwrap! (get assignee task) (err u108)))
        (current-wip (default-to u0 (map-get? member-wip assignee)))
        (deps (default-to (list) (map-get? task-dependencies task-id))))
    (begin
      (asserts! (is-eq assignee tx-sender) (err u109))
      (asserts! (< new-status u3) (err u110))
      (if (is-eq new-status u1)
        (asserts! (are-dependencies-completed deps) (err u117))
        true
      )
      (map-set tasks task-id (merge task { status: new-status, updated-at: block-height }))
      (if (is-eq new-status u2)
        (map-set member-wip assignee (- current-wip u1))
        true
      )
      (ok true)
    )
  )
)

(define-read-only (get-task (task-id uint))
  (map-get? tasks task-id)
)

(define-read-only (get-member-wip (member principal))
  (default-to u0 (map-get? member-wip member))
)

(define-read-only (is-team-member (member principal))
  (is-some (map-get? team-members member))
)

(define-public (set-max-wip (new-max uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err u111))
    (var-set max-wip-per-member new-max)
    (ok true)
  )
)

(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err u112))
    (var-set contract-owner new-owner)
    (ok true)
  )
)

(define-public (submit-feedback (task-id uint) (feedback (string-ascii 512)) (rating uint))
  (let ((task (unwrap! (map-get? tasks task-id) (err u113)))
        (existing-feedback (default-to (list) (map-get? task-feedback task-id))))
    (begin
      (asserts! (is-some (map-get? team-members tx-sender)) (err u114))
      (asserts! (is-eq (get status task) u2) (err u115))
      (asserts! (<= rating u5) (err u116))
      (map-set task-feedback task-id (append existing-feedback { reviewer: tx-sender, feedback: feedback, rating: rating }))
      (ok true)
    )
  )
)

(define-read-only (get-task-feedback (task-id uint))
  (map-get? task-feedback task-id)
)

(define-read-only (get-task-dependencies (task-id uint))
  (map-get? task-dependencies task-id)
)
