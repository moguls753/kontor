module Api
  module V1
    class RecurringSeriesController < ApplicationController
      include ScopedAccounts

      def index
        scope = Current.user.recurring_series
                       .includes(:category, transaction_records: %i[account transfer_counterpart_account])

        # §4b: scope the series to the active lens. "familie" (all accounts) never
        # narrows, so only filter in "privat": drop any series whose members are ALL
        # out of scope (e.g. booked only on a shared/Gemeinschafts-account). A series
        # with no members is left untouched (nothing to place out of scope). The
        # §4a in_scope rule means a cross-scope transfer leg still counts as in-scope
        # here, so a mixed transfer series stays visible in "privat".
        if params[:scope] == "privat"
          ids = scoped_account_ids
          if ids.empty?
            scope = scope.none
          else
            # ids of series that have ≥1 member booked on an in-scope account. Keyed
            # on account membership ONLY (not the §4a in_scope exclusion): a personal→
            # personal transfer has BOTH legs in scope, so the §4a net-zero
            # exclusion would leave it zero in-scope members and wrongly hide the whole
            # series in "privat". A series booked on an in-scope account stays visible.
            in_scope_series = TransactionRecord.where(account_id: ids)
                                .where.not(recurring_series_id: nil)
                                .select(:recurring_series_id)
            # ids of series that have ANY member at all.
            any_member = TransactionRecord.where.not(recurring_series_id: nil)
                                          .select(:recurring_series_id)
            # keep: series with no members OR with ≥1 in-scope member. Subqueries (not
            # plucked arrays) so empty results never produce invalid `IN ()` SQL.
            scope = scope.where(
              "recurring_series.id IN (#{in_scope_series.to_sql}) " \
              "OR recurring_series.id NOT IN (#{any_member.to_sql})"
            )
          end
        end

        # default: show only ACTIVE series. "ended" (the pattern stopped) and "dismissed"
        # are hidden from this page — it's a live overview of running contracts, not a
        # history. Opt in to a specific status (e.g. ?status=ended) to see them.
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.where(status: "active") if params[:status].blank?

        scope = scope.where(direction: params[:direction]) if params[:direction].present?

        # Consumption-type merchants (supermarkets/shops/transport) are NOT contracts and
        # are always hidden from this page. B1′ — NULL-safe predicate: a plain
        # `merchant_type NOT IN (...)` drops NULL rows in SQLite (NULL NOT IN → NULL →
        # excluded), which would hide nearly every series. NULL is the common case and MUST
        # stay visible, so guard it explicitly.
        scope = scope.where(
          "merchant_type IS NULL OR merchant_type NOT IN (?)",
          RecurringSeries::CONSUMPTION_TYPES
        )

        # NOTE: irregular series are NOT filtered here on purpose — that's the detector's
        # job. It drops irregular at detection (Lever A) and ends any old irregular leftover
        # (reconcile_vanished → status: "ended"), which the active-only default above already
        # hides. One source of truth: the detector decides validity, the index shows active.

        scope = scope.order(Arel.sql("CASE WHEN status = 'active' THEN 0 ELSE 1 END"))
                     .order(Arel.sql("next_expected_on IS NULL, next_expected_on ASC"))
                     .order(confidence: :desc)

        # Derive each series' Topf (flow_bucket: expense / income / transfer) from preloaded
        # members. Transfers (pure net-zero moves between own accounts) stay hidden unless
        # ?include_transfers=true (the Transfers tab opts in).
        buckets = scope.to_a.to_h { |s| [ s, s.flow_bucket(members: s.transaction_records.to_a) ] }
        unless params[:include_transfers] == "true"
          buckets.reject! { |_s, b| b == "transfer" }
        end
        series = buckets.keys

        render json: {
          series: series.map { |s| recurring_series_json(s, flow_bucket: buckets[s]) },
          meta: {
            active: series.count { |s| s.status == "active" },
            total: series.size
          }
        }
      end

      def show
        series = Current.user.recurring_series.find(params[:id])
        members = series.transaction_records.includes(:account, :category).order(booking_date: :desc, id: :desc)
        render json: {
          series: recurring_series_json(series),
          transactions: members.map { |tx| transaction_json(tx) }
        }
      end

      def detect
        # Run the full post-sync pipeline ASYNC (categorize → match transfers →
        # detect recurring) instead of blocking the request inline (~13s). Debounced
        # per user via the job's Solid Queue concurrency control.
        ProcessAccountDataJob.perform_later(Current.user.id)
        render json: { queued: true }
      end

      def update
        series = Current.user.recurring_series.find(params[:id])
        series.update!(update_params)
        render json: recurring_series_json(series)
      end

      def destroy
        series = Current.user.recurring_series.find(params[:id])
        # soft delete: dismiss + nullify member links so it isn't re-detected/resurrected
        RecurringSeries.transaction do
          series.transaction_records.update_all(recurring_series_id: nil)
          series.update!(status: "dismissed")
        end
        head :no_content
      end

      private

      def update_params
        permitted = params.require(:recurring_series).permit(:user_confirmed, :category_id, :status, :canonical_name)
        # only allow user-settable statuses
        permitted.delete(:status) unless %w[active dismissed].include?(permitted[:status])
        # defensively drop a foreign category_id so the request fails cleanly (the
        # model validation is authoritative; this avoids leaking another user's data)
        if permitted[:category_id].present? && !Current.user.categories.exists?(id: permitted[:category_id])
          permitted.delete(:category_id)
        end
        permitted
      end

      def recurring_series_json(s, flow_bucket: nil)
        {
          id: s.id,
          flow_bucket: flow_bucket || s.flow_bucket,
          canonical_name: s.canonical_name,
          merchant_type: s.merchant_type,
          direction: s.direction,
          cadence: s.cadence,
          cadence_days: s.cadence_days,
          expected_amount: s.expected_amount,
          amount_variable: s.amount_variable,
          amount_min: s.amount_min,
          amount_max: s.amount_max,
          currency: s.currency,
          confidence: s.confidence,
          confidence_band: confidence_band(s.confidence),
          status: s.status,
          user_confirmed: s.user_confirmed,
          occurrences_count: s.occurrences_count,
          first_seen_on: s.first_seen_on,
          last_seen_on: s.last_seen_on,
          next_expected_on: s.next_expected_on,
          category: s.category ? { id: s.category.id, name: s.category.name } : nil
        }
      end

      def confidence_band(confidence)
        c = confidence.to_f
        return "high" if c >= 0.66
        return "medium" if c >= 0.4

        "low"
      end

      def transaction_json(tx)
        {
          id: tx.id,
          transaction_id: tx.transaction_id,
          amount: tx.amount,
          currency: tx.currency,
          booking_date: tx.booking_date,
          value_date: tx.value_date,
          status: tx.status,
          remittance: tx.remittance,
          creditor_name: tx.creditor_name,
          creditor_iban: tx.creditor_iban,
          debtor_name: tx.debtor_name,
          debtor_iban: tx.debtor_iban,
          bank_transaction_code: tx.bank_transaction_code,
          category: tx.category ? { id: tx.category.id, name: tx.category.name } : nil,
          account_id: tx.account_id,
          account_name: tx.account.name
        }
      end
    end
  end
end
