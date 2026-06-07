class AddCircuitBreakerToBankConnections < ActiveRecord::Migration[8.1]
  def change
    # Net-new columns for the PayPal manual-sync circuit breaker + rate limiter.
    # Inert for every other provider (nothing reads them outside the paypal path):
    #   consecutive_failures   - count of consecutive captcha/push-timeout syncs;
    #                            at N the connection is forced to "error" (re-pair)
    #   last_login_attempt_at  - stamped at the START of every sync_paypal so the
    #                            ~1/day rate limit can reject bursts (NOT reused
    #                            from last_synced_at, which is success-time).
    add_column :bank_connections, :consecutive_failures, :integer, null: false, default: 0
    add_column :bank_connections, :last_login_attempt_at, :datetime
  end
end
