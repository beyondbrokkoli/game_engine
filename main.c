#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdalign.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#ifdef _WIN32
    #define EXPORT __declspec(dllexport)
    #include <windows.h>
    #define SLEEP_MS(ms) Sleep(ms)
    typedef HANDLE vmath_thread_t;
    #define THREAD_FUNC DWORD WINAPI
    #define THREAD_RETURN_VAL 0
    static vmath_thread_t vmath_thread_start(DWORD (WINAPI *func)(LPVOID), void* arg) { return CreateThread(NULL, 0, func, arg, 0, NULL); }
    static void vmath_thread_join(vmath_thread_t thread) { WaitForSingleObject(thread, INFINITE); CloseHandle(thread); }
#else
    #define EXPORT __attribute__((visibility("default")))
    #include <pthread.h>
    #include <unistd.h>
    #define SLEEP_MS(ms) usleep((ms) * 1000)
    typedef pthread_t vmath_thread_t;
    #define THREAD_FUNC void*
    #define THREAD_RETURN_VAL NULL
    static vmath_thread_t vmath_thread_start(void* (*func)(void*), void* arg) { pthread_t thread; pthread_create(&thread, NULL, func, arg); return thread; }
    static void vmath_thread_join(vmath_thread_t thread) { pthread_join(thread, NULL); }
#endif

// =====================================================================
// 1. THE C11 LOCK-FREE TRIPLE-BUFFER MAILBOX
// =====================================================================
typedef struct {
    alignas(64) _Atomic int ready_index;
    _Atomic int is_running;
    _Atomic int lua_finished; // The anti-deadlock handshake flag
} IPC_Mailbox;

typedef struct {
    IPC_Mailbox mailbox;
    int render_index;
    int write_index;
} EngineState;

static EngineState g_engine;

// --- OPAQUE C89 API FOR LUA FFI ---
EXPORT int vibe_get_is_running() {
    return atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_relaxed);
}

EXPORT int vibe_publish_and_get_next_buffer() {
    g_engine.write_index = atomic_exchange_explicit(
        &g_engine.mailbox.ready_index,
        g_engine.write_index,
        memory_order_release
    );
    return g_engine.write_index;
}

EXPORT void vibe_trigger_shutdown() {
    atomic_store_explicit(&g_engine.mailbox.is_running, 0, memory_order_release);
}

EXPORT void vibe_mark_lua_finished() {
    atomic_store_explicit(&g_engine.mailbox.lua_finished, 1, memory_order_release);
}

// --- INTERNAL C ROUTINES ---
void vibe_init_mailbox() {
    atomic_init(&g_engine.mailbox.ready_index, 0);
    atomic_init(&g_engine.mailbox.is_running, 1);
    atomic_init(&g_engine.mailbox.lua_finished, 0);
    g_engine.render_index = 1;
    g_engine.write_index = 2;
}

void vibe_acquire_newest_frame() {
    g_engine.render_index = atomic_exchange_explicit(
        &g_engine.mailbox.ready_index,
        g_engine.render_index,
        memory_order_acquire
    );
}

// =====================================================================
// 2. MAIN ENTRY POINT
// =====================================================================
THREAD_FUNC lua_co_overlord_loop(void* arg) {
    printf("[LUA-OS-THREAD] Booting Lua VM...\n");
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    if (luaL_dofile(L, "main.lua") != LUA_OK) {
        printf("\n[LUA FATAL ERROR] %s\n", lua_tostring(L, -1));
    }
    lua_close(L);
    printf("[LUA-OS-THREAD] VM Destroyed.\n");
    return THREAD_RETURN_VAL;
}

int main(int argc, char** argv) {
    printf("[C-CORE] Booting Minified Concurrent Pipeline...\n");

    vibe_init_mailbox();

    // Spawn the Lua thread
    vmath_thread_t lua_thread = vmath_thread_start(lua_co_overlord_loop, NULL);

    int frame_count = 0;

    // THE SIMULATED RENDER LOOP
    while (vibe_get_is_running()) {
        // 1. Grab newest frame from Lua
        vibe_acquire_newest_frame();

        // 2. Simulate Rendering Work
        if (frame_count % 30 == 0) {
            printf("[C-RENDER] Drawing from Buffer Index: %d\n", g_engine.render_index);
        }
        frame_count++;

        // 3. Sleep ~16ms to simulate a 60FPS V-Sync (and save your CPU)
        SLEEP_MS(16);
    }

    printf("\n[C-CORE] Shutdown triggered. Waiting for Lua handshake...\n");

    // The Anti-Deadlock Spin-Wait
    while (atomic_load_explicit(&g_engine.mailbox.lua_finished, memory_order_acquire) == 0) {
        SLEEP_MS(1); // Non-blocking wait
    }

    // Handshake received. Safe to reel in the thread.
    vmath_thread_join(lua_thread);

    printf("[C-CORE] Clean Exit.\n");
    return 0;
}
