# Do not share a stream between processes
# The token would be shared so putting would give InvalidSequenceTokenException a lot
struct CloudWatchLogHandler{F<:Formatter} <: Handler{F, Union{}}
    stream::CloudWatchLogStream
    channel::Channel{LogEvent}  # only one task should read from this channel
    fmt::F
end

"""
    CloudWatchLogHandler(
        config::AWSConfig,
        log_group_name,
        log_stream_name,
        formatter::Memento.Formatter,
    )

Construct a Memento Handler for logging to a CloudWatch Log Stream.
This constructor creates a task which asynchronously submits logs to the stream.

A CloudWatch Log Event has only two properties: `timestamp` and `message`.

If a `Record` has a `date` property it will be used as the `timestamp`, otherwise the
current time will be captured when `Memento.emit` is called.
All `DateTime`s will be assumed to be in UTC.

The `message` will be generated by calling `Memento.format` on the `Record` with this
handler's `formatter`.
"""
function CloudWatchLogHandler(
    config::AWSConfig,
    log_group_name::AbstractString,
    log_stream_name::AbstractString,
    formatter::F=DefaultFormatter(),
) where F<:Formatter
    ch = Channel{LogEvent}(Inf)
    cwlh = CloudWatchLogHandler(
        CloudWatchLogStream(config, log_group_name, log_stream_name),
        ch,
        formatter,
    )

    tsk = @schedule process_logs!(cwlh)
    # channel will be closed if task fails, to avoid unknowingly discarding logs
    bind(ch, tsk)

    return cwlh
end

function process_available_logs!(cwlh::CloudWatchLogHandler)
    events = Vector{LogEvent}()
    batch_size = 0

    while isready(cwlh.channel) && length(events) <= MAX_BATCH_LENGTH
        event = fetch(cwlh.channel)
        batch_size += aws_size(event)
        if batch_size <= MAX_BATCH_SIZE
            take!(cwlh.channel)
            push!(events, event)
        else
            break
        end
    end

    @mock submit_logs(cwlh.stream, events)
end

"""
    process_logs!(cwlh::CloudWatchLogHandler)

Continually pulls logs from the handler's channel and submits them to AWS.
This function should terminate silently when the channel is closed.
"""
function process_logs!(cwlh::CloudWatchLogHandler)
    group = cwlh.stream.log_group_name
    stream = cwlh.stream.log_stream_name

    debug(LOGGER, "Handler for group '$group' stream '$stream' initiated")

    try
        while isopen(cwlh.channel)  # might be able to avoid the error in this case
            wait(cwlh.channel)
            process_available_logs!(cwlh)
        end
    catch err
        if !(err isa InvalidStateException && err.state === :closed)
            log(
                LOGGER,
                :error,
                "Handler for group '$group' stream '$stream' terminated unexpectedly",
            )
            error(LOGGER, CapturedException(err, catch_backtrace()))
        end
    end

    debug(LOGGER, "Handler for group '$group' stream '$stream' terminated normally")

    return nothing
end

function Memento.emit(cwlh::CloudWatchLogHandler, record::Record)
    dt = haskey(record, :date) ? record[:date] : Dates.now(tz"UTC")
    message = format(cwlh.fmt, record)
    event = LogEvent(message, dt)
    put!(cwlh.channel, event)
end
