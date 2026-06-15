# frozen_string_literal: true

class CreateTradeRepublicItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Per-family Trade Republic connection. Stores the (encrypted) session and
    # refresh tokens obtained from the tr-auth sidecar after the phone+PIN+2FA
    # login. Credentials (phone/PIN) themselves are never persisted.
    create_table :trade_republic_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      # Institution metadata (kept for parity with other provider items)
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      # Status and lifecycle
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false

      # Auth state
      t.string :phone_number
      t.text :session_token       # encrypted
      t.text :refresh_token       # encrypted
      t.datetime :expires_at
      t.text :pending_process_id  # transient processId between /initiate and /complete

      # Sync settings
      t.datetime :sync_start_date

      # Raw data storage
      t.jsonb :raw_payload

      t.timestamps
    end

    add_index :trade_republic_items, :status

    # Individual Trade Republic sub-accounts (cash + securities portfolio).
    create_table :trade_republic_accounts, id: :uuid do |t|
      t.references :trade_republic_item, null: false, foreign_key: true, type: :uuid

      # Account identification (trade_republic_account_id is a stable external id
      # such as "tr_cash" / "tr_securities")
      t.string :name
      t.string :trade_republic_account_id

      # Account details
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :cash_balance, precision: 19, scale: 4, default: 0.0
      t.string :account_status
      t.string :account_type
      t.string :provider

      # Holdings / raw data
      t.jsonb :raw_payload
      t.jsonb :raw_holdings_payload, default: []
      t.datetime :last_holdings_sync

      # Sync settings
      t.date :sync_start_date

      t.timestamps
    end

    add_index :trade_republic_accounts,
              [ :trade_republic_item_id, :trade_republic_account_id ],
              unique: true,
              name: "index_tr_accounts_on_item_and_external_id"
  end
end
