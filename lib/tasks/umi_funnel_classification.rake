# frozen_string_literal: true

namespace :umi do
  namespace :funnel do
    namespace :classification do
      desc 'Export complete private review contexts from an explicit sample manifest without inference'
      task export: :environment do
        manifest = JSON.parse(File.read(ENV.fetch('MANIFEST')))
        packet = Umi::Funnel::ClassificationReview.export(account_id: Integer(ENV.fetch('ACCOUNT_ID')), manifest: manifest)
        Umi::Funnel::ClassificationReview.write_new!(ENV.fetch('OUTPUT'), packet)
      end

      desc 'Infer proposals for an exported private review packet; never apply CRM changes'
      task infer: :environment do
        packet = JSON.parse(File.read(ENV.fetch('INPUT')))
        Umi::Funnel::ClassificationReview.write_new!(ENV.fetch('OUTPUT'), Umi::Funnel::ClassificationReview.infer(packet))
      end
    end
  end
end
