# FreeRTOS test boundary

```mermaid
flowchart LR
    Runtime[production runtime] --> Headers[queue/task/semaphore declarations]
    Headers --> Harness[cooperative host fakes]
```

| File | Purpose | Status |
|---|---|---|
| `FreeRTOS.h` | Scalar types and success/tick constants | ✅ Host compiled |
| `queue.h` | Bounded FIFO API used by offline writer | ✅ Host tested |
| `task.h`, `semphr.h` | Audio/task and app-lock boundary | ✅ Host tested |

Start with [the parent harness map](../README.md). No scheduler or hardware claim;
implementations live in `test_offline_runtime.c` and `test_audio_runtime.c`.
