class AddUniqueContactAvatarAttachmentIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_active_storage_contact_avatar_uniqueness'.freeze

  def up
    add_index :active_storage_attachments,
              [:record_type, :record_id, :name],
              unique: true,
              where: "record_type = 'Contact' AND name = 'avatar'",
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :active_storage_attachments, name: INDEX_NAME, algorithm: :concurrently
  end
end
