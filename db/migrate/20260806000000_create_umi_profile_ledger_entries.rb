class CreateUmiProfileLedgerEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :umi_profile_ledger_entries do |t|
      t.string :run_id, null: false
      t.bigint :contact_id, null: false
      t.bigint :contact_inbox_id
      t.string :attribute_name, null: false
      t.string :old_value
      t.string :new_value
      t.string :evidence_source, null: false
      t.string :graph_response_digest
      t.datetime :created_at, null: false
    end

    add_index :umi_profile_ledger_entries, :run_id
    add_index :umi_profile_ledger_entries, :contact_id
    # Retention sweeps delete by age; without this they scan the whole table.
    add_index :umi_profile_ledger_entries, :created_at
  end
end
