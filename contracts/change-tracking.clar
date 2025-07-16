;; Change Tracking Contract
;; Tracks all data modifications and updates

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-CHANGE-NOT-FOUND (err u401))
(define-constant ERR-INVALID-INPUT (err u402))
(define-constant ERR-INVALID-CHANGE-TYPE (err u403))

;; Data Variables
(define-data-var next-change-id uint u1)
(define-data-var total-changes uint u0)
(define-data-var contract-owner principal tx-sender)

;; Data Maps
(define-map data-changes
  { change-id: uint }
  {
    trail-id: uint,
    entity-id: (string-ascii 100),
    change-type: (string-ascii 30),
    field-name: (string-ascii 50),
    old-value-hash: (buff 32),
    new-value-hash: (buff 32),
    changed-by: principal,
    timestamp: uint,
    reason: (string-ascii 200),
    approved: bool
  }
)

(define-map change-approvals
  { change-id: uint }
  {
    approver: principal,
    approval-timestamp: uint,
    approval-notes: (string-ascii 300)
  }
)

(define-map entity-change-history
  { entity-id: (string-ascii 100), version: uint }
  {
    change-id: uint,
    timestamp: uint,
    change-summary: (string-ascii 200)
  }
)

(define-map entity-versions
  { entity-id: (string-ascii 100) }
  { current-version: uint }
)

(define-map change-statistics
  { date: uint }
  {
    total-changes: uint,
    approved-changes: uint,
    rejected-changes: uint,
    pending-changes: uint
  }
)

;; Authorized managers map
(define-map authorized-managers
  { principal: principal }
  { authorized: bool }
)

;; Public Functions

;; Authorize a manager
(define-public (authorize-manager (manager-principal principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-set authorized-managers { principal: manager-principal } { authorized: true })
    (ok true)
  )
)

;; Track a data change
(define-public (track-change
  (trail-id uint)
  (entity-id (string-ascii 100))
  (change-type (string-ascii 30))
  (field-name (string-ascii 50))
  (old-value-hash (buff 32))
  (new-value-hash (buff 32))
  (reason (string-ascii 200)))
  (let
    (
      (change-id (var-get next-change-id))
      (current-block block-height)
      (current-date (/ current-block u144))
      (current-version (default-to u0 (get current-version (map-get? entity-versions { entity-id: entity-id }))))
      (new-version (+ current-version u1))
    )
    ;; Check if caller is authorized
    (asserts! (default-to false (get authorized (map-get? authorized-managers { principal: tx-sender }))) ERR-NOT-AUTHORIZED)

    (asserts! (or (is-eq change-type "create") (is-eq change-type "update") (is-eq change-type "delete") (is-eq change-type "restore")) ERR-INVALID-CHANGE-TYPE)
    (asserts! (> (len entity-id) u0) ERR-INVALID-INPUT)
    (asserts! (> (len field-name) u0) ERR-INVALID-INPUT)
    (asserts! (> (len reason) u0) ERR-INVALID-INPUT)

    ;; Record the change
    (map-set data-changes
      { change-id: change-id }
      {
        trail-id: trail-id,
        entity-id: entity-id,
        change-type: change-type,
        field-name: field-name,
        old-value-hash: old-value-hash,
        new-value-hash: new-value-hash,
        changed-by: tx-sender,
        timestamp: current-block,
        reason: reason,
        approved: false
      }
    )

    ;; Update entity version history
    (map-set entity-change-history
      { entity-id: entity-id, version: new-version }
      {
        change-id: change-id,
        timestamp: current-block,
        change-summary: reason
      }
    )

    ;; Update entity current version
    (map-set entity-versions
      { entity-id: entity-id }
      { current-version: new-version }
    )

    ;; Update daily statistics
    (let
      (
        (current-stats (default-to
          { total-changes: u0, approved-changes: u0, rejected-changes: u0, pending-changes: u0 }
          (map-get? change-statistics { date: current-date })
        ))
      )
      (map-set change-statistics
        { date: current-date }
        (merge current-stats
          {
            total-changes: (+ (get total-changes current-stats) u1),
            pending-changes: (+ (get pending-changes current-stats) u1)
          }
        )
      )
    )

    ;; Update counters
    (var-set next-change-id (+ change-id u1))
    (var-set total-changes (+ (var-get total-changes) u1))

    (ok change-id)
  )
)

;; Approve a change
(define-public (approve-change (change-id uint) (approval-notes (string-ascii 300)))
  (let
    (
      (change-data (unwrap! (map-get? data-changes { change-id: change-id }) ERR-CHANGE-NOT-FOUND))
      (current-block block-height)
      (current-date (/ current-block u144))
    )
    ;; Check if caller is authorized
    (asserts! (default-to false (get authorized (map-get? authorized-managers { principal: tx-sender }))) ERR-NOT-AUTHORIZED)

    ;; Update change approval status
    (map-set data-changes
      { change-id: change-id }
      (merge change-data { approved: true })
    )

    ;; Record approval details
    (map-set change-approvals
      { change-id: change-id }
      {
        approver: tx-sender,
        approval-timestamp: current-block,
        approval-notes: approval-notes
      }
    )

    ;; Update daily statistics
    (let
      (
        (current-stats (default-to
          { total-changes: u0, approved-changes: u0, rejected-changes: u0, pending-changes: u0 }
          (map-get? change-statistics { date: current-date })
        ))
      )
      (map-set change-statistics
        { date: current-date }
        (merge current-stats
          {
            approved-changes: (+ (get approved-changes current-stats) u1),
            pending-changes: (if (> (get pending-changes current-stats) u0)
                              (- (get pending-changes current-stats) u1)
                              u0)
          }
        )
      )
    )

    (ok true)
  )
)

;; Batch approve changes
(define-public (batch-approve-changes (change-ids (list 10 uint)) (approval-notes (string-ascii 300)))
  (let
    (
      (approval-results (map approve-single-change change-ids))
    )
    ;; Check if caller is authorized
    (asserts! (default-to false (get authorized (map-get? authorized-managers { principal: tx-sender }))) ERR-NOT-AUTHORIZED)

    (ok approval-results)
  )
)

;; Helper function for batch approval
(define-private (approve-single-change (change-id uint))
  (let
    (
      (change-data (map-get? data-changes { change-id: change-id }))
    )
    (match change-data
      data (begin
        (map-set data-changes
          { change-id: change-id }
          (merge data { approved: true })
        )
        (map-set change-approvals
          { change-id: change-id }
          {
            approver: tx-sender,
            approval-timestamp: block-height,
            approval-notes: "Batch approval"
          }
        )
        true
      )
      false
    )
  )
)

;; Revert a change (create compensating change)
(define-public (revert-change (original-change-id uint) (revert-reason (string-ascii 200)))
  (let
    (
      (original-change (unwrap! (map-get? data-changes { change-id: original-change-id }) ERR-CHANGE-NOT-FOUND))
    )
    ;; Check if caller is authorized
    (asserts! (default-to false (get authorized (map-get? authorized-managers { principal: tx-sender }))) ERR-NOT-AUTHORIZED)

    ;; Create compensating change entry
    (try! (track-change
      (get trail-id original-change)
      (get entity-id original-change)
      "revert"
      (get field-name original-change)
      (get new-value-hash original-change)  ;; Swap old and new
      (get old-value-hash original-change)
      revert-reason
    ))

    (ok true)
  )
)

;; Read-only Functions

;; Get change details
(define-read-only (get-change (change-id uint))
  (map-get? data-changes { change-id: change-id })
)

;; Get change approval details
(define-read-only (get-change-approval (change-id uint))
  (map-get? change-approvals { change-id: change-id })
)

;; Get entity version history
(define-read-only (get-entity-history (entity-id (string-ascii 100)) (version uint))
  (map-get? entity-change-history { entity-id: entity-id, version: version })
)

;; Get current entity version
(define-read-only (get-entity-version (entity-id (string-ascii 100)))
  (map-get? entity-versions { entity-id: entity-id })
)

;; Get daily change statistics
(define-read-only (get-daily-change-stats (date uint))
  (map-get? change-statistics { date: date })
)

;; Get total changes count
(define-read-only (get-total-changes)
  (var-get total-changes)
)

;; Check if change is approved
(define-read-only (is-change-approved (change-id uint))
  (match (map-get? data-changes { change-id: change-id })
    change-data (get approved change-data)
    false
  )
)

;; Get changes by entity
(define-read-only (get-entity-change-count (entity-id (string-ascii 100)))
  (match (map-get? entity-versions { entity-id: entity-id })
    version-data (get current-version version-data)
    u0
  )
)

;; Check if manager is authorized
(define-read-only (is-manager-authorized (manager-principal principal))
  (default-to false (get authorized (map-get? authorized-managers { principal: manager-principal })))
)
