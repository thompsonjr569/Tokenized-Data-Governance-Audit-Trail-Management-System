;; Access Logging Contract
;; Logs all data access events in real-time

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-INVALID-ACCESS-TYPE (err u301))
(define-constant ERR-LOG-NOT-FOUND (err u302))
(define-constant ERR-INVALID-INPUT (err u303))

;; Data Variables
(define-data-var next-log-id uint u1)
(define-data-var total-logs uint u0)
(define-data-var contract-owner principal tx-sender)

;; Data Maps
(define-map access-logs
  { log-id: uint }
  {
    trail-id: uint,
    accessor: principal,
    access-type: (string-ascii 20),
    resource: (string-ascii 100),
    timestamp: uint,
    ip-hash: (buff 32),
    session-id: (string-ascii 50),
    success: bool
  }
)

(define-map daily-access-stats
  { date: uint, accessor: principal }
  {
    read-count: uint,
    write-count: uint,
    admin-count: uint,
    failed-attempts: uint
  }
)

(define-map resource-access-counts
  { resource: (string-ascii 100) }
  {
    total-accesses: uint,
    unique-accessors: uint,
    last-access: uint
  }
)

(define-map user-sessions
  { session-id: (string-ascii 50) }
  {
    user: principal,
    start-time: uint,
    last-activity: uint,
    access-count: uint,
    active: bool
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

;; Log data access event
(define-public (log-access
  (trail-id uint)
  (accessor principal)
  (access-type (string-ascii 20))
  (resource (string-ascii 100))
  (ip-hash (buff 32))
  (session-id (string-ascii 50)))
  (let
    (
      (log-id (var-get next-log-id))
      (current-block block-height)
      (current-date (/ current-block u144)) ;; Approximate daily blocks
      (success true)
    )
    ;; Check if caller is authorized
    (asserts! (default-to false (get authorized (map-get? authorized-managers { principal: tx-sender }))) ERR-NOT-AUTHORIZED)

    (asserts! (or (is-eq access-type "read") (is-eq access-type "write") (is-eq access-type "admin") (is-eq access-type "audit")) ERR-INVALID-ACCESS-TYPE)
    (asserts! (> (len resource) u0) ERR-INVALID-INPUT)
    (asserts! (> (len session-id) u0) ERR-INVALID-INPUT)

    ;; Create access log entry
    (map-set access-logs
      { log-id: log-id }
      {
        trail-id: trail-id,
        accessor: accessor,
        access-type: access-type,
        resource: resource,
        timestamp: current-block,
        ip-hash: ip-hash,
        session-id: session-id,
        success: success
      }
    )

    ;; Update daily stats
    (let
      (
        (current-stats (default-to
          { read-count: u0, write-count: u0, admin-count: u0, failed-attempts: u0 }
          (map-get? daily-access-stats { date: current-date, accessor: accessor })
        ))
      )
      (map-set daily-access-stats
        { date: current-date, accessor: accessor }
        (if (is-eq access-type "read")
          (merge current-stats { read-count: (+ (get read-count current-stats) u1) })
          (if (is-eq access-type "write")
            (merge current-stats { write-count: (+ (get write-count current-stats) u1) })
            (if (is-eq access-type "admin")
              (merge current-stats { admin-count: (+ (get admin-count current-stats) u1) })
              current-stats
            )
          )
        )
      )
    )

    ;; Update resource access counts
    (let
      (
        (resource-stats (default-to
          { total-accesses: u0, unique-accessors: u0, last-access: u0 }
          (map-get? resource-access-counts { resource: resource })
        ))
      )
      (map-set resource-access-counts
        { resource: resource }
        (merge resource-stats
          {
            total-accesses: (+ (get total-accesses resource-stats) u1),
            last-access: current-block
          }
        )
      )
    )

    ;; Update session activity
    (let
      (
        (session-data (default-to
          { user: accessor, start-time: current-block, last-activity: current-block, access-count: u0, active: true }
          (map-get? user-sessions { session-id: session-id })
        ))
      )
      (map-set user-sessions
        { session-id: session-id }
        (merge session-data
          {
            last-activity: current-block,
            access-count: (+ (get access-count session-data) u1)
          }
        )
      )
    )

    ;; Update counters
    (var-set next-log-id (+ log-id u1))
    (var-set total-logs (+ (var-get total-logs) u1))

    (ok log-id)
  )
)

;; Log failed access attempt
(define-public (log-failed-access
  (trail-id uint)
  (accessor principal)
  (access-type (string-ascii 20))
  (resource (string-ascii 100))
  (ip-hash (buff 32))
  (session-id (string-ascii 50))
  (failure-reason (string-ascii 100)))
  (let
    (
      (log-id (var-get next-log-id))
      (current-block block-height)
      (current-date (/ current-block u144))
    )
    ;; Check if caller is authorized
    (asserts! (default-to false (get authorized (map-get? authorized-managers { principal: tx-sender }))) ERR-NOT-AUTHORIZED)

    ;; Create failed access log entry
    (map-set access-logs
      { log-id: log-id }
      {
        trail-id: trail-id,
        accessor: accessor,
        access-type: access-type,
        resource: resource,
        timestamp: current-block,
        ip-hash: ip-hash,
        session-id: session-id,
        success: false
      }
    )

    ;; Update failed attempts in daily stats
    (let
      (
        (current-stats (default-to
          { read-count: u0, write-count: u0, admin-count: u0, failed-attempts: u0 }
          (map-get? daily-access-stats { date: current-date, accessor: accessor })
        ))
      )
      (map-set daily-access-stats
        { date: current-date, accessor: accessor }
        (merge current-stats { failed-attempts: (+ (get failed-attempts current-stats) u1) })
      )
    )

    ;; Update counters
    (var-set next-log-id (+ log-id u1))
    (var-set total-logs (+ (var-get total-logs) u1))

    (ok log-id)
  )
)

;; End user session
(define-public (end-session (session-id (string-ascii 50)))
  (let
    (
      (session-data (unwrap! (map-get? user-sessions { session-id: session-id }) ERR-LOG-NOT-FOUND))
    )
    ;; Check if caller is authorized
    (asserts! (default-to false (get authorized (map-get? authorized-managers { principal: tx-sender }))) ERR-NOT-AUTHORIZED)

    (map-set user-sessions
      { session-id: session-id }
      (merge session-data { active: false })
    )

    (ok true)
  )
)

;; Bulk log cleanup (for old entries)
(define-public (cleanup-old-logs (cutoff-block uint))
  (begin
    ;; Only contract owner can cleanup
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (< cutoff-block block-height) ERR-INVALID-INPUT)

    ;; This would require iteration in a real implementation
    ;; For now, just return success
    (ok true)
  )
)

;; Read-only Functions

;; Get access log entry
(define-read-only (get-access-log (log-id uint))
  (map-get? access-logs { log-id: log-id })
)

;; Get daily access stats
(define-read-only (get-daily-stats (date uint) (accessor principal))
  (map-get? daily-access-stats { date: date, accessor: accessor })
)

;; Get resource access counts
(define-read-only (get-resource-stats (resource (string-ascii 100)))
  (map-get? resource-access-counts { resource: resource })
)

;; Get user session info
(define-read-only (get-session-info (session-id (string-ascii 50)))
  (map-get? user-sessions { session-id: session-id })
)

;; Get total logs count
(define-read-only (get-total-logs)
  (var-get total-logs)
)

;; Check if session is active
(define-read-only (is-session-active (session-id (string-ascii 50)))
  (match (map-get? user-sessions { session-id: session-id })
    session-data (get active session-data)
    false
  )
)

;; Get access count for user on date
(define-read-only (get-user-access-count (date uint) (accessor principal))
  (match (map-get? daily-access-stats { date: date, accessor: accessor })
    stats (+ (+ (get read-count stats) (get write-count stats)) (get admin-count stats))
    u0
  )
)

;; Check if manager is authorized
(define-read-only (is-manager-authorized (manager-principal principal))
  (default-to false (get authorized (map-get? authorized-managers { principal: manager-principal })))
)
