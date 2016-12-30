class AppPerfAgentWorker < ActiveJob::Base
  queue_as :app_perf

  attr_accessor :license_key,
                :name,
                :host,
                :data,
                :user,
                :application,
                :protocol_version

  def perform(params)
    #AppPerfRpm.without_tracing do
      self.license_key      = params.fetch(:license_key) { nil }
      self.protocol_version = params.fetch(:protocol_version) { nil }
      self.host             = params.fetch(:host)
      self.name             = params.fetch(:name) { nil }

      if self.license_key.nil? ||
         self.protocol_version.nil? ||
         self.name.nil?
        return
      end

      self.data             = Array(params.fetch(:data))
      self.user             = User.find_by_license_key(license_key)
      self.application      = user.applications.where(:name => name).first_or_initialize
      self.application.license_key = license_key
      self.application.save

      if application
        self.host = application.hosts.where(:name => host).first_or_create

        if protocol_version.to_i.eql?(2)
          errors, samples = data.partition {|d| d[0] == "error" }

          if errors.present?
            process_error_data(errors)
          end

          if samples.present?
            process_version_2(samples)
          end
        end
      end
    #end
  end

  private

  def load_data(data)
    data
      .map {|datum|
        _layer, _trace_key, _start, _duration, _serialized_opts = datum
        begin
          _opts = YAML.load(_serialized_opts).with_indifferent_access
        rescue => ex
          Rails.logger.error "SERIALIZATION ERROR"
          Rails.logger.error _serialized_opts.inspect
          _opts = {}
        end
        [_layer, _trace_key, _start, _duration, _opts]
      }
  end

  def load_layers(data)
    existing_layers = application.layers.all
    layer_names = data.map {|d| d[0] }.compact.uniq
    new_layers = (layer_names - existing_layers.map(&:name)).map {|l|
      application.layers.where(:name => l).first_or_create
    }
    (new_layers + existing_layers).uniq {|l| l.name }
  end

  def load_database_types(data)
    existing_database_types = application.database_types.all
    database_type_names = data
      .map {|d| d[4]["adapter"] }
      .compact
      .uniq
    new_database_types = (database_type_names - existing_database_types.map(&:name)).map {|adapter|
      database_type = application.database_types.where(
        :name => adapter
      ).first_or_create
    }
    (new_database_types + existing_database_types).uniq {|l| l.name }
  end

  def load_traces(data)
    traces = []
    timestamps = data
      .group_by {|datum| datum[1] }
      .flat_map {|trace_key, events| { trace_key => events.map {|e| e[2] }.max } }
      .reduce({}) { |h, v| h.merge v }
    durations = data
      .group_by {|datum| datum[1] }
      .flat_map {|trace_key, events| { trace_key => events.map {|e| e[3] }.max } }
      .reduce({}) { |h, v| h.merge v }

    trace_keys = data.map {|d| d[1] }.compact.uniq
    existing_traces = application.traces.where(:trace_key => trace_keys)

    trace_keys.each {|trace_key|
      timestamp = Time.at(timestamps[trace_key])
      duration = durations[trace_key]

      trace = existing_traces.find {|t| t.trace_key == trace_key }
      if trace.nil?
        trace = application.traces.new(:trace_key => trace_key)
      end

      trace.host = host
      trace.trace_key = trace_key

      # Set timestamp if never set, or incoming timestamp is earlier than
      # the oldest recorded already.
      if trace.timestamp.nil? || trace.timestamp > timestamp
        trace.timestamp = timestamp
      end

      # Set the duration if never set, or the incoming duration is slower
      # than the previous.
      if trace.duration.nil? || trace.duration < duration
        trace.duration = duration
      end

      if trace.new_record?
        traces << trace
      else
        trace.save
      end
    }
    ids = Trace.import(traces).ids
    new_traces = application.traces.where(:id => ids)
    (new_traces + existing_traces).uniq {|t| t.trace_key }
  end

  def process_version_2(data)
    events = []
    samples = []
    database_calls = []

    data = load_data(data)
    layers = load_layers(data)
    database_types = load_database_types(data)
    traces = load_traces(data)

    data.each do |_layer, _trace_key, _start, _duration, _opts|
      hash = {}

      layer = layers.find {|l| l.name == _layer }

      endpoint = nil
      database_call = nil
      url = _opts.fetch("url") { nil }
      domain = _opts.fetch("domain") { nil }
      controller = _opts.fetch("controller") { nil }
      action = _opts.fetch("action") { nil }
      sql = _opts.fetch("sql") { nil }
      adapter = _opts.fetch("adapter") { nil }
      sample_type = _opts.fetch("type") { "web" }

      timestamp = Time.at(_start)
      duration = _duration

      if controller && action
        endpoint = application.transaction_endpoints.where(
          :name => "#{controller}##{action}",
          :controller => controller,
          :action => action
        ).first_or_create
        hash[:transaction_endpoint_id] = endpoint.id
      end

      if sql
        database_type = database_types.find {|dt| dt.name == adapter }
        database_call = application.database_calls.new(
          :uuid => SecureRandom.uuid,
          :database_type_id => database_type.id,
          :host_id => host.id,
          :layer_id => layer.id,
          :statement => sql,
          :timestamp => timestamp,
          :duration => _duration
        )
        database_calls << database_call
      end

      sample = {}
      if endpoint
        sample[:transaction_endpoint_id] = endpoint.id
      end
      if database_call
        sample[:grouping_id] = database_call.uuid
        sample[:grouping_type] = "DatabaseCall"
      end
      sample[:sample_type] = sample_type
      sample[:host_id] = host.id
      sample[:layer_id] = layer.id
      sample[:timestamp] = timestamp
      sample[:duration] = _duration
      sample[:trace_key] = _trace_key
      sample[:payload] = _opts
      sample[:url] = url
      sample[:domain] = domain
      sample[:controller] = controller
      sample[:action] = action
      samples << sample
    end

    all_events = []
    samples.select {|s| s[:trace_key] }.group_by {|s| s[:trace_key] }.each_pair do |trace_key, events|
      timestamp = events.map {|e| e[:timestamp] }.min
      duration = events.map {|e| e[:duration] }.max
      url = (events.find {|e| e[:url] } || {}).fetch(:url) { nil }
      domain = (events.find {|e| e[:domain] } || {}).fetch(:domain) { nil }
      controller = (events.find {|e| e[:controller] } || {}).fetch(:controller) { nil }
      action = (events.find {|e| e[:action] } || {}).fetch(:action) { nil }
      events.each { |e|
        e[:url] ||= url
        e[:domain] ||= domain
        e[:controller] ||= controller
        e[:action] ||= action
      }

      trace = traces.find {|t| t.trace_key == trace_key }
      root = arrange(events, trace)
      flattened_sample = flatten_sample(root)

      all_events += flattened_sample
    end

    samples = all_events.map {|s| application.transaction_sample_data.new(s) }

    TransactionSampleDatum.import(samples)
    DatabaseCall.import(database_calls)
  end

  def flatten_sample(root, depth = 0)
    children_sample = root.delete(:children) || []
    children = if children_sample.present?
      root[:request_id] = generate_trace_id
      children_sample.map do |child|
        child[:parent_id] = root[:request_id]
        flatten_sample(child)
      end
    else
      []
    end

    root[:exclusive_duration] ||= root[:duration] - children_sample.inject(0.0) { |sum, child| sum + child[:duration] }

    [root] + children.flatten
  end

  def arrange(events, trace)
    while event = events.shift
      event[:trace_id] = trace.id
      if parent = events.find { |n|
          start = (n[:timestamp] - event[:timestamp])
          start <= 0 && (start + n[:duration] >= event[:duration])
        }
        parent[:children] ||= []
        parent[:children] << event
      elsif events.empty?
        root = event
      end
    end
    root
  end

  def generate_trace_id
    Digest::SHA1.hexdigest([Time.now, rand].join)
  end

  def process_analytic_event_data(data)
    analytic_event_data = []
    data.each do |datum|
      datum[:host_id] = host.id
      analytic_event_data << application.analytic_event_data.new(datum)
    end
    AnalyticEventDatum.import(analytic_event_data)
  end

  def process_error_data(data)
    error_data = []
    data.select {|d| d.first.eql?("error") }.each do |datum|
      _, trace_key, timestamp, data = datum
      message, backtrace, fingerprint = generate_fingerprint(data[:message], data[:backtrace])

      error_message = application.error_messages.where(:fingerprint => fingerprint).first_or_initialize
      error_message.error_class ||= data[:error_class]
      error_message.error_message ||= message
      error_message.last_error_at = Time.now
      error_message.save

      error_data << application.error_data.new do |error_datum|
        error_datum.host = host
        error_datum.error_message = error_message
        error_datum.transaction_id = trace_key
        error_datum.message = message
        error_datum.backtrace = backtrace
        error_datum.timestamp = timestamp
      end
    end
    ErrorDatum.import(error_data)
  end

  def generate_fingerprint(message, backtrace)
    message, fingerprint = ErrorMessage.generate_fingerprint(message)
    return message, backtrace, fingerprint
  end
end
