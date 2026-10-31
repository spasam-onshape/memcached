-- route_allasync with background retries (one reused handle per child) and
-- back-pressure (max_pending).
pools{
    main = {
        backends = {
            "127.0.0.1:12191",
        }
    }
}

routes{
    cmap = {
        delete = route_allasync{
            children = { "main" },
            retry = { retry_for = 10, backoff = 0.1, backoff_max = 0.1, attempts = 4 },
        },
        -- max_pending = 0: every request waits for its children
        touch = route_allasync{
            children = { "main" },
            max_pending = 0,
            pending_wait = 5,
        },
        -- max_pending = 1: throttles only if requests parked in a retry loop
        -- are (wrongly) counted, ie; after a reload lost the retry state.
        decr = route_allasync{
            children = { "main" },
            max_pending = 1,
            pending_wait = 5,
        },
    },
    default = route_direct{ child = "main" },
}
