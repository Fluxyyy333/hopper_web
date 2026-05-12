-- Rejoin Tool v1.0 — Multi-Package Keepalive + Device Diagnostics
-- Standalone Termux TUI. No web backend needed.
-- Pastikan setiap package selalu in-game di PS-nya.

local CONFIG_FILE = "/sdcard/.rejoin_config"
local STOP_FILE   = "/sdcard/.rejoin_stop"
local LOG_FILE    = "/sdcard/rejoin_log.txt"

-- ============================================
-- HELPERS
-- ============================================
local function sleep(s)
    if s and s > 0 then os.execute("sleep " .. tostring(s)) end
end

local function su_exec(cmd)
    os.execute("su -c '" .. cmd:gsub("'","'\\''") .. "' >/dev/null 2>&1")
end

local function su_read(cmd)
    local h = io.popen("su -c '" .. cmd:gsub("'","'\\''") .. "' 2>/dev/null")
    if not h then return "" end
    local r = h:read("*a") or ""; h:close()
    return r
end

local function shell_read(cmd)
    local h = io.popen(cmd .. " 2>/dev/null")
    if not h then return "" end
    local r = h:read("*a") or ""; h:close()
    return r
end

local function out(text)
    io.write((text or "") .. "\r\n"); io.flush()
end

local function cls()
    io.write("\27[2J\27[3J\27[H\27[0m"); io.flush()
end

local function fix_tty()
    os.execute("stty sane 2>/dev/null")
end

local function ask(prompt)
    io.write(prompt .. " > "); io.flush()
    local tty = io.open("/dev/tty", "r")
    local r
    if tty then r = tty:read("*l"); tty:close()
    else r = io.read("*l") end
    return r and r:gsub("^%s+",""):gsub("%s+$","") or ""
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local c = f:read("*a") or ""; f:close()
    return c:gsub("^%s+",""):gsub("%s+$","")
end

local function save_file(path, content)
    local f = io.open(path, "w")
    if f then f:write(content); f:close() end
end

local function log(msg)
    local line = os.date("[%H:%M:%S] ") .. msg
    local f = io.open(LOG_FILE, "a")
    if f then f:write(line .. "\n"); f:close() end
    out(line)
end

local function tty_sleep(s)
    os.execute("sh -c 'read -t " .. tostring(s)
        .. " _HL </dev/tty 2>/dev/null"
        .. "; case \"$_HL\" in 0) touch " .. STOP_FILE .. ";; esac' 2>/dev/null")
end

local function safe_num(val, default)
    local n = tonumber(tostring(val or ""))
    if n and n == n then return n end
    return default or 0
end

-- ANSI colors
local GREEN  = "\27[32m"
local RED    = "\27[31m"
local YELLOW = "\27[33m"
local CYAN   = "\27[36m"
local RESET  = "\27[0m"
local BOLD   = "\27[1m"

-- ============================================
-- CONFIG (simple JSON parse/write)
-- ============================================
local CONFIG = { cycle_time = 90, packages = {} }

local function parse_json_config(raw)
    local cfg = { packages = {} }
    cfg.cycle_time = safe_num(raw:match('"cycle_time"%s*:%s*(%d+)'), 90)
    for pkg, ps in raw:gmatch('"pkg"%s*:%s*"([^"]+)"%s*,%s*"ps"%s*:%s*"([^"]*)"') do
        table.insert(cfg.packages, { pkg = pkg, ps = ps })
    end
    return cfg
end

local function serialize_config(cfg)
    local lines = { '{' }
    table.insert(lines, '  "cycle_time": ' .. cfg.cycle_time .. ',')
    table.insert(lines, '  "packages": [')
    for i, p in ipairs(cfg.packages) do
        local comma = (i < #cfg.packages) and "," or ""
        table.insert(lines, '    {"pkg": "' .. p.pkg .. '", "ps": "' .. p.ps .. '"}' .. comma)
    end
    table.insert(lines, '  ]')
    table.insert(lines, '}')
    return table.concat(lines, "\n")
end

local function load_config()
    if file_exists(CONFIG_FILE) then
        local raw = read_file(CONFIG_FILE)
        if raw ~= "" then
            CONFIG = parse_json_config(raw)
        end
    end
end

local function save_config()
    save_file(CONFIG_FILE, serialize_config(CONFIG))
end

-- ============================================
-- DEVICE DIAGNOSTICS
-- ============================================
local function check_ok(label, value, ok, fix)
    local status = ok and (GREEN .. "OK" .. RESET) or (RED .. "FAIL" .. RESET)
    out(string.format("  %-22s %-30s %s", label, value, status))
    if not ok and fix then
        out("                         " .. YELLOW .. "→ " .. fix .. RESET)
    end
end

local function run_diagnostics()
    cls()
    out(BOLD .. "╔══════════════════════════════════════════════════════════╗" .. RESET)
    out(BOLD .. "║              Device Diagnostics                         ║" .. RESET)
    out(BOLD .. "╚══════════════════════════════════════════════════════════╝" .. RESET)
    out("")

    -- su access
    local su_id = su_read("id"):gsub("%s+","")
    local su_ok = su_id:match("uid=0")
    check_ok("Root access", su_ok and "uid=0" or su_id:sub(1,30), su_ok, "Install Magisu/su")

    -- RAM
    local mem_raw = shell_read("free -m")
    local mem_total, mem_used, mem_free = mem_raw:match("Mem:%s+(%d+)%s+(%d+)%s+(%d+)")
    mem_free = safe_num(mem_free, 0)
    mem_total = safe_num(mem_total, 0)
    check_ok("RAM", mem_free .. "MB free / " .. mem_total .. "MB total", mem_free >= 200,
        "Close unused apps, free RAM < 200MB")

    -- CPU load
    local load_raw = shell_read("cat /proc/loadavg")
    local load1 = load_raw:match("([%d%.]+)")
    local load_val = safe_num(load1, 0)
    check_ok("CPU load", load1 or "?", load_val < 2.0, "High CPU load, reduce processes")

    -- Storage
    local df_raw = shell_read("df /data 2>/dev/null | tail -1")
    local avail_kb = df_raw:match("%s(%d+)%s+%d+%%%s")
    local avail_mb = safe_num(avail_kb, 0) / 1024
    check_ok("Storage /data", string.format("%.0fMB free", avail_mb), avail_mb >= 500,
        "Low storage, clear app data/cache")

    -- sdcardfs gid
    local mnt = su_read("mount | grep '/mnt/runtime/default/emulated' | head -1")
    local gid = mnt:match(",gid=(%d+)") or "?"
    check_ok("sdcardfs gid", "gid=" .. gid, gid == "9997",
        "Run: su -c 'mount -o remount,gid=9997 /mnt/runtime/default/emulated'")

    -- android_id
    local aid = su_read("settings get secure android_id"):gsub("%s+","")
    check_ok("android_id", aid ~= "" and aid or "(empty)", aid ~= "",
        "Set via: settings put secure android_id <value>")

    -- serial
    local ser = su_read("getprop ro.serialno"):gsub("%s+","")
    check_ok("ro.serialno", ser ~= "" and ser or "(empty)", ser ~= "" and ser ~= "unknown",
        "Set via resetprop ro.serialno <value>")

    -- resetprop
    local rp = su_read("test -x /data/local/tmp/resetprop && echo Y"):match("Y")
    check_ok("resetprop", rp and "/data/local/tmp/resetprop" or "not found", rp,
        "Extract from spoofer APK or install manually")

    -- Installed Roblox clones
    out("")
    out(BOLD .. "  Installed Roblox packages:" .. RESET)
    local pkgs_raw = su_read("pm list packages 2>/dev/null | grep com.delt")
    local pkg_count = 0
    for line in pkgs_raw:gmatch("[^\n]+") do
        local pkg = line:match("package:(.+)")
        if pkg then
            pkg = pkg:gsub("%s+","")
            local act = su_read("pm resolve-activity --brief -a android.intent.action.MAIN"
                .. " -c android.intent.category.LAUNCHER " .. pkg .. " 2>/dev/null | tail -1")
            act = act:gsub("[%c%s]","")
            local launchable = act ~= "" and act:find("/", 1, true)
            local status = launchable and (GREEN .. "launchable" .. RESET) or (RED .. "no activity" .. RESET)
            out("    " .. pkg .. "  " .. status)
            pkg_count = pkg_count + 1
        end
    end
    if pkg_count == 0 then
        out("    " .. RED .. "(none found)" .. RESET)
    end

    out("")
    ask("Enter untuk kembali")
end

-- ============================================
-- PACKAGE MANAGEMENT
-- ============================================
local function short_ps(ps)
    if ps == "" then return "(no PS)" end
    local code = ps:match("privateServerLinkCode=([^&]+)") or ps:match("code=([^&]+)")
    if code then return "...code=" .. code:sub(1, 12) .. "..." end
    return ps:sub(1, 40) .. "..."
end

local function menu_packages()
    while true do
        cls()
        out(BOLD .. "╔══════════════════════════════════════════════════════════╗" .. RESET)
        out(BOLD .. "║            Manage Packages + PS Assignment              ║" .. RESET)
        out(BOLD .. "╚══════════════════════════════════════════════════════════╝" .. RESET)
        out("")
        if #CONFIG.packages == 0 then
            out("  (no packages configured)")
        else
            for i, p in ipairs(CONFIG.packages) do
                out(string.format("  [%d] %s → %s", i, p.pkg, short_ps(p.ps)))
            end
        end
        out("")
        out("  A. Auto-detect installed packages")
        out("  N. Add package + assign PS")
        out("  R. Remove package")
        out("  E. Edit PS for package")
        out("  B. Back")
        out("")
        local ch = ask("Pilih"):upper()

        if ch == "B" then
            return
        elseif ch == "A" then
            local pkgs_raw = su_read("pm list packages 2>/dev/null | grep com.delt")
            local existing = {}
            for _, p in ipairs(CONFIG.packages) do existing[p.pkg] = true end
            local added = 0
            for line in pkgs_raw:gmatch("[^\n]+") do
                local pkg = line:match("package:(.+)")
                if pkg then
                    pkg = pkg:gsub("%s+","")
                    if not existing[pkg] then
                        table.insert(CONFIG.packages, { pkg = pkg, ps = "" })
                        existing[pkg] = true
                        added = added + 1
                    end
                end
            end
            table.sort(CONFIG.packages, function(a,b) return a.pkg < b.pkg end)
            save_config()
            out(GREEN .. "  Added " .. added .. " new package(s)" .. RESET)
            sleep(1)
        elseif ch == "N" then
            local pkg = ask("Package name (e.g. com.deltb)")
            if pkg ~= "" then
                local ps = ask("PS link untuk " .. pkg)
                table.insert(CONFIG.packages, { pkg = pkg, ps = ps or "" })
                save_config()
                out(GREEN .. "  Added " .. pkg .. RESET)
                sleep(1)
            end
        elseif ch == "R" then
            local idx = safe_num(ask("Nomor package yang mau dihapus"), 0)
            if idx >= 1 and idx <= #CONFIG.packages then
                local removed = CONFIG.packages[idx].pkg
                table.remove(CONFIG.packages, idx)
                save_config()
                out(GREEN .. "  Removed " .. removed .. RESET)
                sleep(1)
            end
        elseif ch == "E" then
            local idx = safe_num(ask("Nomor package yang mau diedit PS-nya"), 0)
            if idx >= 1 and idx <= #CONFIG.packages then
                out("  Current: " .. short_ps(CONFIG.packages[idx].ps))
                local ps = ask("PS link baru")
                if ps ~= "" then
                    CONFIG.packages[idx].ps = ps
                    save_config()
                    out(GREEN .. "  Updated" .. RESET)
                    sleep(1)
                end
            end
        end
    end
end

-- ============================================
-- LAUNCH & OPTIMIZE (from hopper.lua.tpl)
-- ============================================
local function is_running(pkg)
    if not pkg or pkg == "" then return false end
    local h = io.popen("su -c 'pidof " .. pkg .. "' 2>/dev/null")
    if not h then return false end
    local r = h:read("*a") or ""; h:close()
    return r:match("%d+") ~= nil
end

local function get_pid(pkg)
    local raw = su_read("pidof " .. pkg .. " 2>/dev/null") or ""
    return raw:match("(%d+)")
end

local function force_low_quality(pkg)
    if pkg == "" then return end
    local prefs_dir = "/data/data/" .. pkg .. "/shared_prefs"
    local gfiles = su_read("ls " .. prefs_dir .. "/GlobalSettings*.xml 2>/dev/null") or ""
    for gfile in gfiles:gmatch("[^\n]+") do
        gfile = gfile:gsub("%s+", "")
        if gfile ~= "" then
            su_exec("sed -i 's|name=\"QualityLevel\" value=\"[^\"]*\"|name=\"QualityLevel\" value=\"1\"|g' '" .. gfile .. "'")
            su_exec("sed -i 's|name=\"SavedQualityLevel\" value=\"[^\"]*\"|name=\"SavedQualityLevel\" value=\"1\"|g' '" .. gfile .. "'")
        end
    end
end

local function post_launch_optimize(pkg)
    sleep(5)
    local pid = get_pid(pkg)
    if not pid then
        log("[optimize] " .. pkg .. " PID not found — skip")
        return
    end
    su_exec("renice -10 -p " .. pid .. " 2>/dev/null")
    su_exec("ionice -c 2 -n 0 -p " .. pid .. " 2>/dev/null")
    su_exec("echo -200 > /proc/" .. pid .. "/oom_score_adj 2>/dev/null")
    local cg = "/dev/memcg/" .. pkg
    su_exec("mkdir -p " .. cg .. " 2>/dev/null")
    su_exec("echo " .. pid .. " > " .. cg .. "/cgroup.procs 2>/dev/null")
    su_exec("echo 629145600 > " .. cg .. "/memory.limit_in_bytes 2>/dev/null")
    su_exec("echo 524288000 > " .. cg .. "/memory.soft_limit_in_bytes 2>/dev/null")
    log("[optimize] " .. pkg .. " PID " .. pid .. " → nice -10, oom -200, memcg 600MB")
end

local function launch_pkg(pkg, ps_link)
    if not ps_link or ps_link == "" then
        log("[launch] " .. pkg .. " SKIP — no PS assigned")
        return false
    end
    log("[launch] " .. pkg .. " → " .. short_ps(ps_link))

    su_exec("am force-stop " .. pkg)
    sleep(2)
    su_exec("rm -rf /data/data/" .. pkg .. "/cache/*")
    su_exec("rm -rf /data/data/" .. pkg .. "/code_cache/*")
    su_exec("rm -rf /sdcard/Android/data/" .. pkg .. "/cache/*")
    su_exec("rm -rf /data/data/" .. pkg .. "/app_webview/Default/GPUCache/* 2>/dev/null")
    su_exec("rm -rf /data/data/" .. pkg .. "/files/logs/* 2>/dev/null")
    su_exec("rm -rf /data/data/" .. pkg .. "/files/shaders/* 2>/dev/null")
    force_low_quality(pkg)

    local dp = ps_link:match("^intent://(.-)#Intent")
           or ps_link:gsub("^https?://","")
    local intent = "intent://" .. dp
        .. "#Intent;scheme=https;package=" .. pkg
        .. ";action=android.intent.action.VIEW;end"
    su_exec('am start --user 0 "' .. intent .. '"')

    post_launch_optimize(pkg)
    return true
end

-- ============================================
-- REJOIN LOOP
-- ============================================
local function run_rejoin()
    if #CONFIG.packages == 0 then
        out(RED .. "  Tidak ada packages. Konfigurasi dulu." .. RESET)
        sleep(2)
        return
    end

    local has_ps = false
    for _, p in ipairs(CONFIG.packages) do
        if p.ps ~= "" then has_ps = true; break end
    end
    if not has_ps then
        out(RED .. "  Tidak ada PS yang di-assign. Assign PS ke minimal 1 package." .. RESET)
        sleep(2)
        return
    end

    cls()
    out(BOLD .. "╔══════════════════════════════════════════════════════════╗" .. RESET)
    out(BOLD .. "║       Rejoin Active — Press 0+Enter to stop             ║" .. RESET)
    out(BOLD .. "╚══════════════════════════════════════════════════════════╝" .. RESET)
    out("")
    out("  Packages: " .. #CONFIG.packages)
    out("  Cycle   : " .. CONFIG.cycle_time .. "s")
    out("  Log     : " .. LOG_FILE)
    out("")

    os.remove(STOP_FILE)
    os.execute("rm -f " .. LOG_FILE .. " 2>/dev/null")

    local cycle = 0
    while true do
        cycle = cycle + 1
        log("=== Cycle " .. cycle .. " ===")

        for i, p in ipairs(CONFIG.packages) do
            if file_exists(STOP_FILE) then
                log("Stop signal detected — exiting rejoin")
                os.remove(STOP_FILE)
                return
            end

            if p.ps == "" then
                log("[" .. i .. "/" .. #CONFIG.packages .. "] " .. p.pkg .. " — SKIP (no PS)")
            elseif is_running(p.pkg) then
                local pid = get_pid(p.pkg) or "?"
                log("[" .. i .. "/" .. #CONFIG.packages .. "] " .. p.pkg .. " PID " .. pid .. " — OK")
            else
                log("[" .. i .. "/" .. #CONFIG.packages .. "] " .. p.pkg .. " NOT RUNNING — launching...")
                launch_pkg(p.pkg, p.ps)
            end
        end

        log("Next cycle in " .. CONFIG.cycle_time .. "s (press 0+Enter to stop)")
        tty_sleep(CONFIG.cycle_time)

        if file_exists(STOP_FILE) then
            log("Stop signal detected — exiting rejoin")
            os.remove(STOP_FILE)
            return
        end
    end
end

-- ============================================
-- MAIN MENU
-- ============================================
local function main_menu()
    while true do
        cls()
        out(BOLD .. "╔══════════════════════════════════════════════════════════╗" .. RESET)
        out(BOLD .. "║              Rejoin Tool v1.0                           ║" .. RESET)
        out(BOLD .. "╠══════════════════════════════════════════════════════════╣" .. RESET)
        if #CONFIG.packages == 0 then
            out(BOLD .. "║  " .. RESET .. "Packages : " .. YELLOW .. "0 (belum dikonfigurasi)" .. RESET)
        else
            out(BOLD .. "║  " .. RESET .. "Packages : " .. #CONFIG.packages .. " configured")
            for _, p in ipairs(CONFIG.packages) do
                local status = p.ps ~= "" and short_ps(p.ps) or (RED .. "(no PS)" .. RESET)
                out(BOLD .. "║  " .. RESET .. "  " .. CYAN .. p.pkg .. RESET .. " → " .. status)
            end
        end
        out(BOLD .. "║  " .. RESET .. "Cycle    : " .. CONFIG.cycle_time .. "s")
        out(BOLD .. "╠══════════════════════════════════════════════════════════╣" .. RESET)
        out(BOLD .. "║  " .. RESET .. "1. Device Diagnostics")
        out(BOLD .. "║  " .. RESET .. "2. Manage Packages + PS")
        out(BOLD .. "║  " .. RESET .. "3. Set Cycle Time")
        out(BOLD .. "║  " .. RESET .. "4. START Rejoin")
        out(BOLD .. "║  " .. RESET .. "0. Exit")
        out(BOLD .. "╚══════════════════════════════════════════════════════════╝" .. RESET)
        out("")
        local ch = ask("Pilih")

        if ch == "0" then
            cls()
            out("Bye.")
            return
        elseif ch == "1" then
            run_diagnostics()
        elseif ch == "2" then
            menu_packages()
        elseif ch == "3" then
            local t = safe_num(ask("Cycle time (detik, default 90)"), 0)
            if t >= 10 then
                CONFIG.cycle_time = t
                save_config()
                out(GREEN .. "  Cycle time set to " .. t .. "s" .. RESET)
                sleep(1)
            else
                out(RED .. "  Minimum 10 detik" .. RESET)
                sleep(1)
            end
        elseif ch == "4" then
            fix_tty()
            run_rejoin()
            fix_tty()
        end
    end
end

-- ============================================
-- ENTRY
-- ============================================
load_config()
main_menu()
