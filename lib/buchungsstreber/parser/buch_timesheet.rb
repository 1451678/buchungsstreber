require 'date'

require_relative '../entry'

# BuchTimesheet parses the layout used by jo.
#
class Buchungsstreber::BuchTimesheet
  include Buchungsstreber::TimesheetParser::Base

  def initialize(file_path, templates, minimum_time)
    @file_path = file_path
    @templates = templates
    @minimum_time = minimum_time

    @model = File.readlines(@file_path) rescue []
  end

  def self.parses?(file)
    File.extname(file) == '.B'
  end

  def parse
    result = Buchungsstreber::Entries.new

    current = nil
    work_hours = nil
    @model.each do |line|
      case line
      when /^([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])/
        # beginning of day
        current = $1
        if line =~ /(?<start>\d{1,2}:\d{1,2}) -> (?<pause>\d{1,2}(?:[:.]\d{1,2})?) -> (?<end>\d{1,2}:\d{1,2})/
          s = Time.parse("#{current} #{$~[:start]}")
          p = parse_time($~[:pause])
          e = Time.parse("#{current} #{$~[:end]}")
          work_hours = minimum_time((e - s) / 60 / 60 - p, @minimum_time)
        else
          work_hours = nil
        end
      when /^%/
        # ignore comment lines
        next
      when /^#\s+(?<time>[0-9]+(?:[.:][0-9]*)?)\s+(?<template>#{@templates.keys.join('|')})/
        template = @templates[$~[:template]]
        time = minimum_time(parse_time($~[:time]), @minimum_time)
        template['issue'] =~ /(?<redmine>[a-z]?)#?(?<issue>[0-9]*)/

        result << Buchungsstreber::Entry.new(
          time: time,
          activity: template['activity'],
          issue: $~[:issue],
          text: template['text'],
          date: parse_date(current),
          redmine: $~[:redmine]
        )
      when /(?<redmine>[a-z]?)#(?<issue>[0-9]*)\s\s*(?<time>[0-9]+(?:[.:][0-9]*)?)\s\s*(?<activity>[a-z]+\s+)?(?<text>.+)/i
        result << Buchungsstreber::Entry.new(
          time: minimum_time(parse_time($~[:time]), @minimum_time),
          activity: ($~[:activity] ? $~[:activity].strip : nil),
          issue: $~[:issue],
          text: $~[:text],
          date: parse_date(current),
          redmine: $~[:redmine],
          work_hours: work_hours,
        )
      when /(?<redmine>[a-z]?)#(?<issue>[0-9]*)\s\s*(?<time>[0-9]+(?:[.:][0-9]*)?)/
        result << Buchungsstreber::Entry.new(
          time: minimum_time(parse_time($~[:time]), @minimum_time),
          issue: $~[:issue],
          date: parse_date(current),
          redmine: $~[:redmine],
          work_hours: work_hours,
        )
      when /^$/
        # ignore empty lines
        next
      when /^\s+(.*)/
        # continuation
        result[-1][:text] += $1
      else
        throw "invalid line #{line}"
      end
    end

    result
  end

  def add(entries)
    # as entries get added on top, reverse the entries before
    entries.reverse.each do |e|
      iso_date = e[:date].to_s
      days = @model.map
                   .with_index { |line, idx| [Date.parse($1), idx] if line =~ /^(\d\d\d\d-\d\d-\d\d)/ }
                   .compact
                   .sort { |x| x[0] }
                   .reverse

      # Find the line of the day to append to
      idx = days.select {|x| x[0] == e[:date] }.map {|x| x[1] }.first

      # or: Find the line of the day to insert new day before
      nidx = days.select {|x| x[0] < e[:date] }.map {|x| x[1] - 1 }.first

      if idx
        @model = @model[0..idx] + [format_entry(e)] + @model[idx+1..-1]
      elsif nidx && nidx < 0
        @model.unshift "#{iso_date}:\n\n", format_entry(e)
      elsif nidx
        @model = @model[0..nidx] + ["#{iso_date}:\n", format_entry(e)] + @model[nidx+1..-1]
      else
        @model << "#{iso_date}\n\n"
        @model << format_entry(e)
      end
    end
  end

  def unparse
    @model.join
  end

  def format(entries)
    buf = ""
    days = entries.group_by { |e| e[:date] }.to_a.sort_by { |x| x[0] }
    days.each do |date, day|
      buf << "#{date}\n\n"
      day.each do |e|
        buf << format_entry(e)
      end
    end
    buf
  end

  def archive(archive_path, date)
    FileUtils.mkdir_p archive_path unless File.directory? archive_path
    archive_filename = "#{date.strftime('%Y-%m-%d')}.B"

    File.open("#{archive_path}/#{archive_filename}", File::WRONLY | File::CREAT | File::EXCL) do |f|
      f.write(File.read(@file_path))
    end
  end

  private

  def format_entry(e)
    buf = ''
    buf << "% #{e[:comment]}\n" if e[:comment]
    buf << "#{e[:redmine]}##{e[:issue]}\t#{minimum_time(e[:time] || 0.0, @minimum_time)}\t#{e[:activity]}\t#{e[:text]}\n"
    buf
  end

  def parse_date(date_descr)
    Date.parse(date_descr)
  end
end
