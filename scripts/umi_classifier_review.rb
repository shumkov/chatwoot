# frozen_string_literal: true

require 'json'
require 'erb'
require 'digest'

module UmiClassifierReview
  TEMPLATE = <<~'HTML'
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <title>UMI classifier review</title>
    <style>body{max-width:960px;margin:2rem auto;padding:1rem;font-family:system-ui}article{border-top:1px solid #ccc;padding:1rem 0}pre{white-space:pre-wrap;overflow-wrap:anywhere}textarea{width:100%;min-height:5rem}.warning{color:#9c4200}details{margin:1rem 0}</style>
    <h1>UMI classifier review</h1><p>Read the proposed result and explain only what is wrong. Retained expectations are shown separately from the new model answer. This page never changes CRM or activates the classifier.</p>
    <% if packet['mode'] == 'retrospective_semantic_qa' %>
      <p class="warning"><strong>Retrospective semantic QA only.</strong> Historical incoming evidence is simulated as fresh for this review. This does not prove production eligibility or advertising attribution. Topic proposals still require production correction checks.</p>
    <% end %>
    <p>Configuration: <code><%= h(packet.fetch('configuration_digest')) %></code></p>
    <% packet.fetch('samples').each do |sample| %>
      <article id="sample-<%= h(sample.fetch('sample')) %>"><h2>Example <%= h(sample.fetch('sample')) %> · conversation #<%= h(sample.fetch('conversation_display_id')) %></h2>
      <p class="warning"><%= h(sample.dig('context', 'coverage')) %>; <%= h(sample.fetch('input_bytes')) %> serialized input bytes. <%= h(sample['warning']) %></p>
      <h3>Last verified customer facts</h3><pre><%= h(JSON.pretty_generate(sample.dig('context', 'customer'))) %></pre>
      <h3>New model proposal</h3><pre><%= h(sample['proposal'] ? JSON.pretty_generate(sample['proposal']) : "No valid result: #{sample['failure'] || 'inference not run'}") %></pre>
      <p>Evidence: <% evidence_ids(sample).each do |id| %><a href="#sample-<%= h(sample.fetch('sample')) %>-message-<%= h(id) %>"><%= h(id) %></a> <% end %></p>
      <h3>Retained expectations and corrections</h3><pre><%= h(JSON.pretty_generate(sample.fetch('human_expectations'))) %></pre>
      <label>What is wrong and why?<textarea data-key="<%= h(sample_key(sample)) %>"><%= h(prefill(sample)) %></textarea></label>
      <details open><summary>Full available conversation</summary>
      <% sample.fetch('context').fetch('messages').each do |message| %>
        <div id="sample-<%= h(sample.fetch('sample')) %>-message-<%= h(message.fetch('id')) %>"><strong><%= h(message.fetch('role')) %> · <%= h(message.fetch('created_at')) %> · ID <%= h(message.fetch('id')) %></strong>
        <pre><%= h(message.fetch('text')) %></pre><% if message['attachments'] %><p class="warning">Attachments present; media content was not read.</p><% end %>
        <% if message['context_only'] %><p>Context only; cannot support a fresh qualification.</p><% end %></div>
      <% end %></details></article>
    <% end %>
    <button id="download">Save corrections</button><p>Missing results, conflicting corrections and disagreements must be resolved before explicit acceptance of this exact packet.</p>
    <script>
    const storageKey = <%= JSON.generate(storage_key).gsub('<', '\\u003c') %>;
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem(storageKey) || '{}'); } catch (_) {}
    document.querySelectorAll('textarea').forEach(field => {
      if (typeof saved[field.dataset.key] === 'string') field.value = saved[field.dataset.key];
      field.addEventListener('input', () => { saved[field.dataset.key] = field.value; localStorage.setItem(storageKey, JSON.stringify(saved)); });
    });
    document.querySelector('#download').addEventListener('click', () => {
      const corrections = Array.from(document.querySelectorAll('textarea'), field => ({sample_conversation: field.dataset.key, text: field.value}));
      const blob = new Blob([JSON.stringify({packet: storageKey, corrections}, null, 2)], {type:'application/json'});
      const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = 'umi-classifier-corrections.json'; link.click(); URL.revokeObjectURL(link.href);
    });
    </script></html>
  HTML

  def self.h(value)
    ERB::Util.html_escape(value.to_s)
  end

  def self.sample_key(sample)
    "#{sample.fetch('sample')}:#{sample.fetch('conversation_display_id')}"
  end

  def self.prefill(sample)
    sample.fetch('human_expectations').map { |entry| "[#{entry.fetch('source')}] #{entry.fetch('text')}" }.join("\n\n")
  end

  def self.evidence_ids(sample)
    proposal = sample['proposal'] || {}
    (Array(proposal['evidence_message_ids']) + (Array(proposal['topics']) + Array(proposal['roles'])).flat_map do |entry|
      entry.fetch('evidence_message_ids')
    end).uniq
  end

  def self.render(packet)
    storage_key = "umi-classifier-review-#{Digest::SHA256.hexdigest(JSON.generate(packet))}"
    ERB.new(TEMPLATE).result(binding)
  end
end

if $PROGRAM_NAME == __FILE__
  input, output = ARGV
  abort 'Usage: ruby scripts/umi_classifier_review.rb INPUT.json NEW_OUTPUT.html' unless input && output
  abort 'Output directory must be private' unless File.stat(File.dirname(File.expand_path(output))).mode.nobits?(0o077)
  packet = JSON.parse(File.read(input))
  File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(UmiClassifierReview.render(packet)) }
end
