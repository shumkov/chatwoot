# frozen_string_literal: true

# Time.zone is per-thread state that outlives an example. Specs that set it
# (spec/models/working_hour_spec.rb ends on Australia/Sydney) never restore it,
# so whichever spec CI's round-robin sharding runs after them in the same
# process inherits that zone, and serialized timestamps change offset. Restore
# the application default after every example.
RSpec.configure do |config|
  config.after { Time.zone = Time.zone_default }
end
