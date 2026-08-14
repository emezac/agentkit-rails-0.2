# frozen_string_literal: true

require "json"
require "fileutils"

module Agentkit
  module RAG
    # Ingestion layer for loading documents from PDF, JSONL, or raw Array.
    class Corpus
      class << self
        def from_pdf(path, merge_pages: false, min_chars: 50, strip_headers_footers: true)
          unless defined?(::PDF::Reader)
            begin
              require "pdf/reader"
            rescue LoadError
              raise LoadError, "The 'pdf-reader' gem is required for PDF ingestion."
            end
          end

          path = File.expand_path(path.to_s)
          raise ArgumentError, "PDF not found: #{path}" unless File.exist?(path)

          reader = PDF::Reader.new(path)
          raw_pages = reader.pages.map.with_index(1) do |page, num|
            text = page.text.to_s
                       .encode("UTF-8", invalid: :replace, undef: :replace, replace: " ")
                       .strip
            { page: num, text: text }
          end

          if strip_headers_footers && raw_pages.size >= 3
            raw_pages = remove_repeated_lines(raw_pages)
          end

          valid_pages = raw_pages.reject { |p| p[:text].length < min_chars }
          basename = File.basename(path, ".*")

          if merge_pages
            text = valid_pages.map { |p| p[:text] }.join("\n\n")
            [{ "id" => "#{basename}_full", "text" => text, "source" => path, "metadata" => {} }]
          else
            valid_pages.map do |page|
              {
                "id"       => "#{basename}_p#{page[:page]}",
                "text"     => page[:text],
                "source"   => path,
                "metadata" => { "page" => page[:page], "source_file" => File.basename(path) }
              }
            end
          end
        end

        def from_jsonl(path)
          path = File.expand_path(path.to_s)
          raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

          docs = []
          File.open(path, "r:UTF-8:UTF-8") do |fh|
            fh.each_line.with_index(1) do |line, lineno|
              line = line.encode("UTF-8", invalid: :replace, undef: :replace).strip
              next if line.empty?

              begin
                docs << JSON.parse(line)
              rescue JSON::ParserError
                # skip malformed line
              end
            end
          end
          docs
        end

        private

        def remove_repeated_lines(pages)
          threshold = (pages.size * 0.6).ceil

          first_lines = pages.map { |p| p[:text].lines.first&.strip }.compact
          last_lines  = pages.map { |p| p[:text].lines.last&.strip }.compact

          repeated_first = first_lines.tally.filter_map { |line, cnt| line if cnt >= threshold && line.length < 120 }
          repeated_last  = last_lines.tally.filter_map  { |line, cnt| line if cnt >= threshold && line.length < 120 }

          pages.map do |page|
            lines = page[:text].lines.map(&:rstrip)
            lines.shift if repeated_first.any? && repeated_first.include?(lines.first&.strip)
            lines.pop   if repeated_last.any?  && repeated_last.include?(lines.last&.strip)
            page.merge(text: lines.join("\n").strip)
          end
        end
      end
    end
  end
end
