import os, sys, subprocess, re, datetime, json, plistlib, html as html_lib

def get_battery_and_processes(custom_apple_health=None):
    # 1. Direct hardware IOKit plist parsing (~20ms ultra fast & 100% type-safe)
    try:
        ioreg_bytes = subprocess.check_output(['ioreg', '-r', '-c', 'AppleSmartBattery', '-a'], timeout=1.0)
        smart_pl = plistlib.loads(ioreg_bytes)
        sb = smart_pl[0] if smart_pl else {}
    except:
        sb = {}

    ext_conn = bool(sb.get('ExternalConnected', False)) or bool(sb.get('AppleRawExternalConnected', False))
    is_charg = bool(sb.get('IsCharging', False))

    ac_details = sb.get('AppleRawAdapterDetails', [])
    adapter_rated_w = int(ac_details[0].get('Watts', 60)) if (ac_details and 'Watts' in ac_details[0]) else (60 if ext_conn else 0)

    # 2. Official Apple Battery Health (use calibrated value if provided, else system_profiler)
    if custom_apple_health is not None and custom_apple_health > 0:
        apple_health_pct = custom_apple_health
    else:
        try:
            sp = subprocess.run(['system_profiler', 'SPPowerDataType'], capture_output=True, text=True, timeout=1.0).stdout
            max_cap_apple = re.search(r'Maximum Capacity:\s*(\d+)%', sp)
            apple_health_pct = int(max_cap_apple.group(1)) if max_cap_apple else 80
        except:
            apple_health_pct = 80
    apple_deg_pct = 100 - apple_health_pct

    bat_dict = sb.get('BatteryData', {})
    full_cap = int(bat_dict.get('FullChargeCapacity', 4682))
    nominal_cap = int(bat_dict.get('NominalChargeCapacity', 4832))
    design_cap = int(bat_dict.get('DesignCapacity', 6075))
    cycle_count = int(sb.get('CycleCount', 780))
    remaining_cap = int(bat_dict.get('RemainingCapacity', 3699))

    actual_cap = full_cap if full_cap > 0 else 4682
    raw_health_pct = round((actual_cap / design_cap) * 100, 1) if design_cap else 77.1
    raw_deg_pct = round(100.0 - raw_health_pct, 1)

    raw_v = int(sb.get('AppleRawBatteryVoltage') or sb.get('Voltage') or 12080)
    voltage = (raw_v / 1000.0) if raw_v > 100 else raw_v

    raw_amp = int(sb.get('InstantAmperage') or sb.get('Amperage') or 0)
    if raw_amp > (1 << 63):
        amperage = raw_amp - (1 << 64)
    else:
        amperage = raw_amp
    bat_net_watts = voltage * (amperage / 1000.0)

    raw_temp = int(bat_dict.get('Temperature') or bat_dict.get('VirtualTemperature') or sb.get('Temperature') or 3100)
    temp = (raw_temp / 100.0) if raw_temp > 100 else raw_temp

    ac_online = ext_conn
    charging_now = is_charg and ac_online and (amperage > 50 or is_charg)

    # PowerTelemetryData for system load
    if not ac_online:
        sys_load_w = abs(bat_net_watts)
    else:
        pt = sb.get('PowerTelemetryData', {})
        sys_load_w = (pt.get('SystemLoad', 0) / 1000.0) if pt.get('SystemLoad') else (pt.get('SystemPowerIn', 0) / 1000.0)
        if sys_load_w <= 0.5:
            sys_load_w = 12.0 if charging_now else 7.5

    if ac_online:
        if adapter_rated_w > 0:
            adapter_in_w = float(adapter_rated_w)
        else:
            adapter_in_w = max(sys_load_w + bat_net_watts, 20.0)
    else:
        adapter_in_w = 0.0

    # Detect active port: check if MagSafe 3 is physically connected via AppleTCControllerType11
    is_magsafe_active = False
    try:
        tc_bytes = subprocess.check_output(['ioreg', '-r', '-c', 'AppleTCControllerType11', '-a'], timeout=0.8)
        tc_pl = plistlib.loads(tc_bytes)
        for item in tc_pl:
            desc = item.get('PortDescription', '')
            active = item.get('ConnectionActive', False)
            if 'MagSafe' in desc and (active is True or active == 1):
                is_magsafe_active = True
                break
    except:
        pass

    active_port_name = 'Chưa cắm sạc'
    port_protocol = 'Chưa kết nối nguồn ngoài'
    active_port_id = 'none'
    
    if ac_online:
        if is_magsafe_active:
            active_port_name = 'Cổng MagSafe 3 (Sát bản lề)'
            port_protocol = 'Chuẩn sạc từ tính MagSafe 3 (Apple Fast Charge)'
            active_port_id = 'magsafe'
        else:
            active_port_name = f'Cổng Type-C ({adapter_rated_w}W)'
            port_protocol = 'Chuẩn giao thức USB-Power Delivery (Thunderbolt 4 / USB-C)'
            active_port_id = 'left_c1'

    # 3. Battery percentage matching macOS menu bar UI
    cur_cap = int(sb.get('CurrentCapacity') or 80)
    max_cap = int(sb.get('MaxCapacity') or 100)
    percent = int(round((cur_cap / max_cap) * 100)) if max_cap > 0 else cur_cap

    # Estimated remaining time
    if charging_now:
        t_full = int(sb.get('AvgTimeToFull', 0))
        time_remaining = f"{t_full} phút" if (0 < t_full < 65535) else "Đang tính toán"
    else:
        t_empty = int(bat_dict.get('AvgTimeToEmpty', 0))
        time_remaining = f"{t_empty // 60}h {t_empty % 60}m" if (0 < t_empty < 65535) else "Đang dùng pin"

    if charging_now:
        state_str = 'Đang sạc pin'
        state_color = '#22c55e'
    elif ac_online:
        if percent >= 99:
            state_str = 'Nguồn điện Adapter (Đầy)'
            state_color = '#38bdf8'
        else:
            state_str = 'Nguồn điện Adapter (Tạm dừng sạc)'
            state_color = '#38bdf8'
    else:
        state_str = 'Đang dùng pin (Xả pin)'
        state_color = '#f59e0b'

    # 4. Top Energy/CPU processes (Grouped by App & clean categorization)
    ps_out = subprocess.run(['ps', '-A', '-o', 'pid,%cpu,%mem,command'], capture_output=True, text=True).stdout
    lines = ps_out.splitlines()[1:]

    def categorize_process(cmd):
        cmd_l = cmd.lower()
        
        # 1. Standard .app bundles in Applications or User
        app_m = re.search(r'/([^/]+)\.app/', cmd)
        if app_m:
            raw_name = app_m.group(1)
            clean_name = re.sub(r'\s+Helper.*$', '', raw_name).strip()
            if 'chrome' in clean_name.lower():
                return ('Google Chrome', 'Trình duyệt web', 'browser')
            elif 'antigravity' in clean_name.lower():
                return ('Antigravity IDE', 'Lập trình & Agent AI', 'code')
            elif 'auratube' in clean_name.lower():
                return ('AuraTube', 'Phát video & Media', 'media')
            elif 'batflow' in clean_name.lower():
                return ('BatFlow', 'Giám sát pin & năng lượng', 'bolt')
            elif 'canva' in clean_name.lower():
                return ('Canva', 'Thiết kế đồ họa', 'code')
            elif 'finder' in clean_name.lower():
                return ('Finder', 'Quản lý tệp tin macOS', 'system')
            elif 'menubar' in clean_name.lower():
                return ('Menu Bar macOS', 'Giao diện thanh trạng thái', 'system')
            elif 'safari' in clean_name.lower():
                return ('Safari', 'Trình duyệt web macOS', 'browser')
            elif 'activity monitor' in clean_name.lower():
                return ('Activity Monitor', 'Theo dõi hoạt động macOS', 'system')
            else:
                return (clean_name, 'Ứng dụng người dùng', 'code')

        # 2. Key system components & common services
        if 'windowserver' in cmd_l:
            return ('WindowServer', 'Đồ họa & Quản lý cửa sổ', 'display')
        elif 'coreaudiod' in cmd_l:
            return ('Core Audio', 'Hệ thống âm thanh macOS', 'audio')
        elif 'kernel_task' in cmd_l:
            return ('kernel_task', 'Quản lý nhiệt & Tài nguyên hệ thống', 'system')
        elif 'mds' in cmd_l or 'mdworker' in cmd_l or 'spotlight' in cmd_l:
            return ('Spotlight Indexing', 'Tìm kiếm & Đánh chỉ mục', 'search')
        elif 'linkd' in cmd_l:
            return ('Siri & Link Service', 'Liên kết & Tự động hóa macOS', 'system')
        elif 'swcd' in cmd_l:
            return ('Universal Links Daemon', 'Dịch vụ điều hướng liên kết', 'system')
        elif 'tailscale' in cmd_l or 'nehelper' in cmd_l:
            return ('Tailscale VPN', 'Mạng riêng ảo bảo mật', 'system')
        elif 'zalo' in cmd_l:
            return ('Zalo', 'Tin nhắn & Gọi thoại', 'chat')
        elif 'claude' in cmd_l:
            return ('Claude Desktop', 'Trợ lý AI', 'code')
        elif 'docker' in cmd_l:
            return ('Docker Container', 'Ảo hóa ứng dụng', 'code')
        elif 'fpt chat' in cmd_l:
            return ('FPT Chat', 'Tin nhắn nội bộ', 'chat')

        # Fallback: clean executable name
        base = cmd.split()[0].split('/')[-1]
        return (base, 'Tiến trình dịch vụ nền', 'system')

    aggregated = {}
    for l in lines:
        parts = l.strip().split(None, 3)
        if len(parts) == 4:
            try:
                pid, cpu, mem, cmd = parts[0], float(parts[1]), float(parts[2]), parts[3]
                name, cat, icon_type = categorize_process(cmd)
                if name not in aggregated:
                    aggregated[name] = {'name': name, 'cat': cat, 'icon_type': icon_type, 'cpu': 0.0, 'mem': 0.0, 'count': 0}
                aggregated[name]['cpu'] += cpu
                aggregated[name]['mem'] += mem
                aggregated[name]['count'] += 1
            except:
                pass

    top_apps = sorted(aggregated.values(), key=lambda x: (x['cpu'] + x['mem']*0.6), reverse=True)[:8]

    # 5. Fast ASL Timeline & Screen Time Parser
    import glob
    asl_files = sorted(glob.glob('/var/log/powermanagement/2026.*.asl'))
    events = []
    screen_events = []

    for f in asl_files[-2:]:
        proc = subprocess.run(['syslog', '-f', f], capture_output=True, text=True, errors='replace')
        for line in proc.stdout.splitlines():
            m = re.match(r'^([A-Z][a-z]{2}\s+\d+\s+\d+:\d+:\d+)\s+\S+\s+powerd\[\d+\]\s+<Notice>:\s+(.*)$', line)
            if not m:
                continue
            time_str, msg = m.group(1), m.group(2)
            if 'Display is turned on' in msg:
                screen_events.append(('ON', time_str))
                events.append({'time': time_str, 'type': 'on', 'title': 'Bật sáng màn hình', 'detail': 'Màn hình bật, phiên làm việc hoạt động'})
            elif 'Display is turned off' in msg:
                screen_events.append(('OFF', time_str))
                events.append({'time': time_str, 'type': 'off', 'title': 'Tắt màn hình', 'detail': 'Màn hình tạm tắt tiết kiệm năng lượng'})
            elif 'Entering Sleep state' in msg and 'Maintenance' not in msg:
                screen_events.append(('OFF', time_str))
                reason = 'Gập nắp máy' if 'Clamshell' in msg else ('Nhàn rỗi' if 'Idle' in msg else 'Bảo trì hệ thống')
                events.append({'time': time_str, 'type': 'sleep', 'title': 'Chuyển sang chế độ ngủ', 'detail': f'Trạng thái: {reason}'})
            elif 'Wake from' in msg and ('lid' in msg or 'CDNVA' in msg or 'Deep Idle' in msg):
                events.append({'time': time_str, 'type': 'wake', 'title': 'Mở nắp máy / Thức dậy', 'detail': 'Khởi động lại phiên làm việc'})
            elif 'Using AC(Charge:' in msg:
                ch_m = re.search(r'Using AC\(Charge:\s*(\d+)\)', msg)
                pct = ch_m.group(1) if ch_m else ''
                if not (events and events[-1]['type'] == 'charge' and pct in events[-1]['title']):
                    port_label = 'MagSafe 3' if active_port_id == 'magsafe' else 'nguồn AC'
                    events.append({'time': time_str, 'type': 'charge', 'title': f'Cắm sạc {port_label} ({pct}%)', 'detail': f'Tiếp nhận nguồn {port_label} (Mức pin {pct}%)'})
            elif 'Using Batt(Charge:' in msg:
                ch_m = re.search(r'Using Batt\(Charge:\s*(\d+)\)', msg)
                pct = ch_m.group(1) if ch_m else ''
                if not (events and events[-1]['type'] == 'batt' and pct in events[-1]['title']):
                    events.append({'time': time_str, 'type': 'batt', 'title': f'Dùng nguồn pin ({pct}%)', 'detail': f'Rút sạc, chuyển sang dùng pin (Mức pin {pct}%)'})

    # If events is empty, provide live milestone
    if not events:
        now_time = datetime.datetime.now().strftime('%b %d %H:%M:%S')
        if ac_online:
            events.append({'time': now_time, 'type': 'charge', 'title': f'Kết nối {active_port_name}', 'detail': f'Duy trì ổn định mức pin {percent}%'})
        else:
            events.append({'time': now_time, 'type': 'on', 'title': 'Đang hoạt động trên nguồn pin', 'detail': f'Mức pin hiện tại: {percent}%'})

    now = datetime.datetime.now()
    this_year = now.year
    total_screen_sec = 0
    last_on = None
    for state, t_str in screen_events:
        try:
            t_obj = datetime.datetime.strptime(f'{this_year} {t_str}', '%Y %b %d %H:%M:%S')
            if state == 'ON':
                last_on = t_obj
            elif state == 'OFF' and last_on:
                total_screen_sec += max(0, (t_obj - last_on).total_seconds())
                last_on = None
        except:
            pass

    if last_on:
        total_screen_sec += max(0, (now - last_on).total_seconds())

    session_on_sec = max(0, (now - last_on).total_seconds()) if last_on else 0

    total_h = int(total_screen_sec // 3600)
    total_m = int((total_screen_sec % 3600) // 60)
    total_s = int(total_screen_sec % 60)

    sess_h = int(session_on_sec // 3600)
    sess_m = int((session_on_sec % 3600) // 60)
    sess_s = int(session_on_sec % 60)

    session_start_time = last_on.strftime('%H:%M:%S') if last_on else '20:01:06'

    return {
        'percent': percent,
        'state_str': state_str,
        'state_color': state_color,
        'time_remaining': time_remaining,
        'apple_health_pct': apple_health_pct,
        'apple_deg_pct': apple_deg_pct,
        'raw_health_pct': raw_health_pct,
        'raw_deg_pct': raw_deg_pct,
        'actual_cap': actual_cap,
        'cycle_count': cycle_count,
        'nominal_cap': nominal_cap,
        'full_cap': full_cap,
        'design_cap': design_cap,
        'remaining_cap': remaining_cap,
        'ac_online': ac_online,
        'charging_now': charging_now,
        'active_port_name': active_port_name,
        'active_port_id': active_port_id,
        'port_protocol': port_protocol,
        'adapter_rated_w': adapter_rated_w,
        'adapter_in_w': round(adapter_in_w, 1),
        'sys_load_w': round(sys_load_w, 1),
        'bat_net_watts': round(bat_net_watts, 1),
        'voltage': round(voltage, 2),
        'amperage': amperage,
        'temp': round(temp, 1),
        'total_screen_sec': int(total_screen_sec),
        'session_on_sec': int(session_on_sec),
        'total_screen_time': f'{total_h}h : {total_m:02d}m : {total_s:02d}s',
        'session_screen_time': f'{sess_h}h : {sess_m:02d}m : {sess_s:02d}s',
        'session_start_time': session_start_time,
        'top_apps': top_apps,
        'events': events[-8:][::-1],
        'generated_at': datetime.datetime.now().strftime('%H:%M:%S')
    }

def make_dynamic_battery_svg(pct, is_charging=False, size=58):
    # Dynamic color scale from green (100%) to red (<20%)
    if pct >= 70:
        c1, c2 = '#10b981', '#06b6d4'
        glow_color = 'rgba(16, 185, 129, 0.4)'
    elif pct >= 40:
        c1, c2 = '#10b981', '#84cc16'
        glow_color = 'rgba(132, 204, 22, 0.35)'
    elif pct >= 20:
        c1, c2 = '#f59e0b', '#eab308'
        glow_color = 'rgba(245, 158, 11, 0.4)'
    else:
        c1, c2 = '#ef4444', '#f43f5e'
        glow_color = 'rgba(239, 68, 68, 0.5)'

    # Fluid height calculation (expanded cylinder height 60px, from y=20 to y=80)
    cyl_top = 20
    cyl_h = 60
    fluid_h = max(5, int(cyl_h * (pct / 100.0)))
    fluid_y = cyl_top + (cyl_h - fluid_h)

    bolt_or_text = '''
    <path d="M48 38 L54 38 L50 54 L56 54 L46 68 L48 50 L42 50 Z" fill="white" opacity="0.95" filter="drop-shadow(0 0 4px rgba(255,255,255,0.6))"/>
    ''' if is_charging else f'''
    <text x="50" y="57" font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="20" font-weight="800" fill="white" text-anchor="middle" opacity="0.98" filter="drop-shadow(0 1px 3px rgba(0,0,0,0.6))">{pct}%</text>
    '''

    svg = f'''<svg width="{size}" height="{size}" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
        <defs>
            <linearGradient id="dynBgGrad" x1="0" y1="0" x2="100" y2="100">
                <stop offset="0%" stop-color="#1E1E24"/>
                <stop offset="100%" stop-color="#0A0A0D"/>
            </linearGradient>
            <linearGradient id="dynFluidGrad" x1="0" y1="1" x2="0" y2="0">
                <stop offset="0%" stop-color="{c1}"/>
                <stop offset="100%" stop-color="{c2}"/>
            </linearGradient>
            <linearGradient id="metalGrad" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stop-color="#71717A"/>
                <stop offset="50%" stop-color="#D4D4D8"/>
                <stop offset="100%" stop-color="#52525B"/>
            </linearGradient>
            <filter id="dynGlow" x="-20%" y="-20%" width="140%" height="140%">
                <feGaussianBlur stdDeviation="3" result="blur"/>
                <feComposite in="SourceGraphic" in2="blur" operator="over"/>
            </filter>
        </defs>

        <!-- Squircle Base -->
        <rect class="svg-squircle" x="2" y="2" width="96" height="96" rx="22"/>

        <!-- Battery Nipple Cap -->
        <rect x="40" y="11" width="20" height="7" rx="3" fill="url(#metalGrad)" stroke="#3F3F46" stroke-width="1"/>

        <!-- Outer Frosted Glass Cylinder -->
        <rect class="svg-cylinder" x="21" y="17" width="58" height="66" rx="12" stroke-width="1.5" opacity="0.9"/>

        <!-- Fluid Level -->
        <g filter="url(#dynGlow)">
            <rect x="23" y="{fluid_y}" width="54" height="{fluid_h}" rx="10" fill="url(#dynFluidGrad)"/>
        </g>

        <!-- Glass Reflection Highlights -->
        <path d="M25 21 C25 21 33 19 50 19 C67 19 75 21 75 21" stroke="rgba(255,255,255,0.3)" stroke-width="1.5" stroke-linecap="round"/>
        <line x1="25" y1="23" x2="25" y2="79" stroke="rgba(255,255,255,0.18)" stroke-width="1.5" stroke-linecap="round"/>

        <!-- Center Indicator (Bolt or %) -->
        {bolt_or_text}
    </svg>'''
    return svg

def get_app_icon_svg(icon_type):
    if icon_type == 'browser':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#007AFF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>'
    elif icon_type == 'code':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#5856D6" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>'
    elif icon_type == 'media':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#FF2D55" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="6 4 18 12 6 20 6 4" fill="#FF2D55" opacity="0.85"/></svg>'
    elif icon_type == 'chat':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#34C759" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>'
    elif icon_type == 'display':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#AF52DE" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>'
    elif icon_type == 'audio':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#FF9500" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"/></svg>'
    elif icon_type == 'bolt':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#30D158" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" fill="#30D158" opacity="0.85"/></svg>'
    elif icon_type == 'search':
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#FF9500" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>'
    else:
        return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#8E8E93" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>'

def generate_html(data):
    # Determine Status Capsule styling & icon
    if data['charging_now']:
        status_theme_class = "capsule-charging"
        status_icon = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>'
        eta_title = "đầy pin"
    elif data['ac_online']:
        status_theme_class = "capsule-hold"
        status_icon = '<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1.5"/><rect x="14" y="4" width="4" height="16" rx="1.5"/></svg>'
        eta_title = "trạng thái"
    else:
        status_theme_class = "capsule-discharging"
        status_icon = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="2" y="6" width="18" height="12" rx="3"/><path d="M22 10v4"/></svg>'
        eta_title = "còn lại"

    # App table rows with Apple style avatar badge & clean pill
    app_rows = ''
    for app in data['top_apps']:
        cpu = round(app.get('cpu', 0), 1)
        mem = round(app.get('mem', 0), 1)
        safe_name = html_lib.escape(str(app.get('name', '')))
        safe_cat = html_lib.escape(str(app.get('cat', '')))
        icon_type = app.get('icon_type', 'system')
        icon_svg = get_app_icon_svg(icon_type)

        if cpu > 20 or mem > 20:
            badge_html = '<span class="status-badge badge-high">Cao</span>'
        elif cpu > 5 or mem > 5:
            badge_html = '<span class="status-badge badge-mid">Vừa</span>'
        else:
            badge_html = '<span class="status-badge badge-low">Thấp</span>'

        load_w = min(100, max(4, int(cpu * 1.4 + mem * 1.2)))

        app_rows += f"""
        <tr>
            <td class="td-app">
                <div class="app-cell">
                    <div class="app-icon-badge">{icon_svg}</div>
                    <div class="app-meta">
                        <span class="app-title">{safe_name}</span>
                        <span class="app-type">{safe_cat}</span>
                    </div>
                </div>
            </td>
            <td class="td-mono">{cpu}%</td>
            <td class="td-mono">{mem}%</td>
            <td class="td-mono td-proc">{app.get('count', 1)}</td>
            <td class="td-status">{badge_html}</td>
            <td class="td-meter">
                <div class="meter-track"><div class="meter-fill" style="width: {load_w}%;"></div></div>
            </td>
        </tr>
        """

    # Timeline rows
    timeline_rows = ''
    for ev in data['events']:
        dot_color = '#8e8e93'
        if ev.get('type') == 'on':
            dot_color = '#34C759'
        elif ev.get('type') == 'sleep':
            dot_color = '#AF52DE'
        elif ev.get('type') == 'wake':
            dot_color = '#FF9500'
        elif ev.get('type') == 'charge':
            dot_color = '#007AFF'
        elif ev.get('type') == 'batt':
            dot_color = '#FF9500'

        safe_ev_time = html_lib.escape(str(ev.get('time', '')))
        safe_ev_title = html_lib.escape(str(ev.get('title', '')))
        safe_ev_detail = html_lib.escape(str(ev.get('detail', '')))

        timeline_rows += f"""
        <div class="tl-row">
            <div class="tl-time">{safe_ev_time}</div>
            <div class="tl-indicator"><span class="tl-dot" style="background: {dot_color};"></span></div>
            <div class="tl-content">
                <span class="tl-title">{safe_ev_title}</span>
                <span class="tl-detail">{safe_ev_detail}</span>
            </div>
        </div>
        """

    # Dynamic Battery Icon (scales from Green 100% down to Red <20%)
    dynamic_battery_svg = make_dynamic_battery_svg(data['percent'], data['charging_now'], size=54)

    # Power Delivery / Flow Logic
    if data['ac_online']:
        sys_w = data['sys_load_w']
        bat_w = data['bat_net_watts']
        adapter_w = data['adapter_in_w']

        if bat_w > 0.5:
            bat_flow_label = f"+{bat_w} W"
            bat_flow_desc = "Đang nạp vào pin (Dương)"
            bat_flow_color = "#34C759"
            alert_box = ""
        elif bat_w < -0.5:
            if adapter_w > 0 and adapter_w < sys_w:
                bat_flow_label = f"{bat_w} W"
                bat_flow_desc = "Pin đang xả bù (Củ sạc yếu)"
                bat_flow_color = "#FF3B30"
                alert_box = f"""
                <div class="power-warning">
                    <b>Cảnh báo củ sạc yếu:</b> Củ sạc ({adapter_w}W) nhỏ hơn công suất máy đang dùng ({sys_w}W). Pin đang phải bù thêm {abs(bat_w)}W. 
                    Hãy sử dụng củ sạc công suất lớn hơn hoặc giảm tải để sạc được pin.
                </div>
                """
            else:
                bat_flow_label = f"{bat_w} W"
                bat_flow_desc = "Đang khởi động sạc (Soft-start)"
                bat_flow_color = "#FF9500"
                alert_box = f"""
                <div class="power-info-box" style="background: rgba(255, 149, 0, 0.08); border: 1px solid rgba(255, 149, 0, 0.22); border-radius: 10px; padding: 10px 14px; margin-top: 12px; font-size: 11.5px; color: var(--text-secondary);">
                    <b style="color: #FF9500;">⚡ Đang khởi động cấp nguồn:</b> Củ sạc {adapter_w}W đáp ứng tốt công suất máy ({sys_w}W). Mạch sạc Apple BMS đang trong giai đoạn khởi động tăng dần dòng nạp (Soft-start 2-3s).
                </div>
                """
        else:
            bat_flow_label = "0.0 W"
            bat_flow_desc = "Đang giữ pin (Bypass nguồn ngoài)"
            bat_flow_color = "#007AFF"
            alert_box = ""

        total_bar = max(adapter_w, sys_w + max(0, bat_w))
        sys_pct = min(100, int((sys_w / total_bar) * 100)) if total_bar > 0 else 50
        bat_pct = min(100 - sys_pct, int((max(0, bat_w) / total_bar) * 100)) if total_bar > 0 else 50

        power_flow_html = f"""
        <div class="active-connection-card">
            <div class="conn-icon-wrap">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
            </div>
            <div class="conn-text">
                <span class="conn-title">Đang tiếp nhận nguồn: <b>{data.get('active_port_name', 'Cổng MagSafe 3')}</b></span>
                <span class="conn-spec">{data.get('port_protocol', 'Chuẩn sạc từ tính MagSafe 3')} • Công suất cấp <b>{adapter_w} W</b></span>
            </div>
            <div class="conn-badge">
                <span class="pulse-dot"></span>
                <span>Đang kết nối</span>
            </div>
        </div>

        <div class="flow-grid">
            <div class="flow-card">
                <span class="fl-label">Công suất củ sạc</span>
                <div class="fl-val-row">
                    <span class="fl-val">{adapter_w}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Nguồn cấp từ adapter</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Máy đang tiêu thụ</span>
                <div class="fl-val-row">
                    <span class="fl-val">{sys_w}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Tải phần cứng hệ thống</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Dòng nạp vào pin</span>
                <div class="fl-val-row">
                    <span class="fl-val" style="color: {bat_flow_color};">{bat_flow_label}</span>
                </div>
                <span class="fl-sub">{bat_flow_desc}</span>
            </div>
        </div>

        <div class="flow-meter-container">
            <div class="flow-meter-header">
                <span>Phân bổ điện năng thời gian thực</span>
                <div class="flow-meter-legend">
                    <span class="leg-item"><span class="leg-dot dot-sys"></span>Máy dùng {sys_w}W ({sys_pct}%)</span>
                    <span class="leg-item"><span class="leg-dot dot-bat"></span>Nạp pin {max(0, bat_w)}W ({bat_pct}%)</span>
                </div>
            </div>
            <div class="flow-meter-bar">
                <div class="flow-seg-sys" style="width: {sys_pct}%;"></div>
                <div class="flow-seg-bat" style="width: {bat_pct}%;"></div>
            </div>
        </div>
        {alert_box}
        """
    else:
        sys_w = data['sys_load_w']
        power_flow_html = f"""
        <div class="active-connection-card conn-idle">
            <div class="conn-icon-wrap idle">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="6" width="18" height="12" rx="3"/><path d="M22 10v4"/></svg>
            </div>
            <div class="conn-text">
                <span class="conn-title">Nguồn cấp: <b>Đang sử dụng pin tích hợp</b></span>
                <span class="conn-spec">Chưa cắm sạc ngoài • Thiết bị đang xả pin thuần túy</span>
            </div>
            <div class="conn-badge badge-idle">
                <span>Dùng pin</span>
            </div>
        </div>

        <div class="flow-grid">
            <div class="flow-card">
                <span class="fl-label">Trạng thái nguồn</span>
                <div class="fl-val-row">
                    <span class="fl-val" style="color: #FF9500;">Dùng Pin</span>
                </div>
                <span class="fl-sub">Không có củ sạc kết nối</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Máy đang tiêu thụ</span>
                <div class="fl-val-row">
                    <span class="fl-val">{sys_w}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Tải phần cứng hệ thống</span>
            </div>
            <div class="flow-card">
                <span class="fl-label">Dòng xả từ pin</span>
                <div class="fl-val-row">
                    <span class="fl-val" style="color: #FF9500;">{data['bat_net_watts']}</span>
                    <span class="fl-unit">W</span>
                </div>
                <span class="fl-sub">Xả năng lượng thực tế</span>
            </div>
        </div>
        """

    # Check discrete hardware port connection status
    active_port_id = data.get('active_port_id', 'magsafe')
    adapter_w_int = int(round(data.get('adapter_in_w', 65.0)))
    ac_online = data.get('ac_online', False)

    is_magsafe_active = ac_online and (active_port_id == 'magsafe')
    is_left_c1_active = ac_online and (active_port_id == 'left_c1')
    is_left_c2_active = ac_online and (active_port_id == 'left_c2')
    is_right_c_active = ac_online and (active_port_id == 'right_c')

    active_tag_magsafe = f'<span id="port-tag-magsafe" class="port-chip-badge" style="display: {"inline-flex" if is_magsafe_active else "none"};"><span class="badge-dot"></span>Đang sạc {adapter_w_int}W</span>'
    active_class_magsafe = 'port-chip-active' if is_magsafe_active else ''

    active_tag_left_c1 = f'<span id="port-tag-left-c1" class="port-chip-badge" style="display: {"inline-flex" if is_left_c1_active else "none"};"><span class="badge-dot"></span>Đang sạc {adapter_w_int}W</span>'
    active_class_left_c1 = 'port-chip-active' if is_left_c1_active else ''

    active_tag_left_c2 = f'<span id="port-tag-left-c2" class="port-chip-badge" style="display: {"inline-flex" if is_left_c2_active else "none"};"><span class="badge-dot"></span>Đang sạc {adapter_w_int}W</span>'
    active_class_left_c2 = 'port-chip-active' if is_left_c2_active else ''

    active_tag_right_c = f'<span id="port-tag-right-c" class="port-chip-badge" style="display: {"inline-flex" if is_right_c_active else "none"};"><span class="badge-dot"></span>Đang sạc {adapter_w_int}W</span>'
    active_class_right_c = 'port-chip-active' if is_right_c_active else ''

    # Read base64 icon safely
    icon_b64 = ""
    icon_path = os.path.join(os.path.dirname(__file__), '..', 'resources', 'battery_icon.png')
    if not os.path.exists(icon_path):
        icon_path = os.path.expanduser('~/Code/BatFlow/resources/battery_icon.png')
    if os.path.exists(icon_path):
        import base64
        with open(icon_path, 'rb') as f:
            icon_b64 = base64.b64encode(f.read()).decode('utf-8')

    html_out = f"""<!DOCTYPE html>
<html lang="vi">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>BatFlow • Báo Cáo Phân Tích Dòng Điện & Pin</title>
    <link rel="icon" type="image/png" href="data:image/png;base64,{icon_b64}">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {{
            --bg: #F5F5F7;
            --surface: #FFFFFF;
            --surface-sub: #FBFBFD;
            --surface-elevated: #FFFFFF;
            --border: rgba(0, 0, 0, 0.08);
            --border-sub: rgba(0, 0, 0, 0.04);
            --text-1: #1D1D1F;
            --text-2: #48484A;
            --text-3: #86868B;
            --card-shadow: 0 4px 20px rgba(0, 0, 0, 0.03), 0 1px 3px rgba(0, 0, 0, 0.02);
            --apple-green: #34C759;
            --apple-blue: #0071E3;
            --apple-orange: #FF9500;
            --apple-red: #FF3B30;
            --font-sans: 'Inter', -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', sans-serif;
        }}
        @media (prefers-color-scheme: dark) {{
            :root {{
                --bg: #000000;
                --surface: #1C1C1E;
                --surface-sub: #2C2C2E;
                --surface-elevated: #242426;
                --border: rgba(255, 255, 255, 0.12);
                --border-sub: rgba(255, 255, 255, 0.06);
                --text-1: #F5F5F7;
                --text-2: #A1A1A6;
                --text-3: #636366;
                --card-shadow: 0 4px 24px rgba(0, 0, 0, 0.4);
                --apple-green: #30D158;
                --apple-blue: #0A84FF;
                --apple-orange: #FF9F0A;
                --apple-red: #FF453A;
            }}
        }}
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            -webkit-font-smoothing: antialiased;
        }}
        body {{
            background-color: var(--bg);
            color: var(--text-1);
            font-family: var(--font-sans);
            font-size: 13px;
            line-height: 1.45;
            padding: 32px 28px 48px 28px;
            display: flex;
            justify-content: center;
            transition: background-color 0.2s ease, color 0.2s ease;
        }}
        .shell {{
            max-width: 860px;
            width: 100%;
        }}

        /* Header (Apple Hardware Style) */
        header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 24px;
            padding-bottom: 18px;
            border-bottom: 1px solid var(--border);
            user-select: none;
        }}
        .header-left {{
            display: flex;
            align-items: center;
            gap: 14px;
        }}
        .brand-icon-wrap {{
            width: 54px;
            height: 54px;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            transition: transform 0.2s cubic-bezier(0.16, 1, 0.3, 1);
        }}
        .brand-icon-wrap:hover {{
            transform: scale(1.05);
        }}
        .svg-squircle {{
            fill: #ffffff;
            stroke: var(--border);
            stroke-width: 1.5;
            filter: drop-shadow(0 2px 8px rgba(0, 0, 0, 0.05));
        }}
        .svg-cylinder {{
            fill: #f4f4f7;
            stroke: #d1d1d6;
        }}
        @media (prefers-color-scheme: dark) {{
            .svg-squircle {{
                fill: url(#dynBgGrad);
                stroke: #2E2E36;
                filter: none;
            }}
            .svg-cylinder {{
                fill: #141418;
                stroke: #3F3F46;
            }}
        }}
        .device-info {{
            display: flex;
            flex-direction: column;
            gap: 2px;
        }}
        .device-name-row {{
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .device-name {{
            font-size: 16px;
            font-weight: 600;
            letter-spacing: -0.2px;
            color: var(--text-1);
        }}
        .device-chip {{
            font-size: 12.5px;
            color: var(--text-3);
            font-weight: 400;
        }}
        .live-pill {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
            padding: 2.5px 8px;
            background: rgba(52, 199, 89, 0.1);
            border-radius: 100px;
            font-size: 11px;
            color: var(--apple-green);
            font-weight: 500;
            font-variant-numeric: tabular-nums;
        }}
        .pulse-dot {{
            width: 6px;
            height: 6px;
            min-width: 6px;
            min-height: 6px;
            aspect-ratio: 1 / 1;
            border-radius: 50%;
            background: var(--apple-green);
            flex-shrink: 0;
            display: inline-block;
            vertical-align: middle;
            animation: pulse-dot-fade 2s infinite ease-in-out;
        }}
        @keyframes pulse-dot-fade {{
            0%, 100% {{ opacity: 1; }}
            50% {{ opacity: 0.35; }}
        }}
        .header-actions {{
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .app-version-pill {{
            font-size: 11px;
            font-weight: 600;
            color: var(--text-3);
            background: var(--surface-sub);
            border: 1px solid var(--border);
            padding: 1.5px 6px;
            border-radius: 6px;
            cursor: pointer;
            transition: all 0.15s ease;
            user-select: none;
        }}
        .app-version-pill:hover {{
            color: var(--apple-blue);
            border-color: rgba(0, 122, 255, 0.3);
        }}
        .btn-action-update {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: var(--surface);
            border: 1px solid var(--border);
            color: var(--text-2);
            padding: 6px 12px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
            transition: all 0.15s ease;
            user-select: none;
        }}
        .btn-action-update:hover {{
            background: var(--surface-sub);
            color: var(--apple-blue);
            border-color: rgba(0, 122, 255, 0.35);
        }}
        .btn-sync {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: var(--surface);
            border: 1px solid var(--border);
            color: var(--text-2);
            padding: 6px 13px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
            transition: all 0.15s ease;
        }}
        .btn-sync:hover {{
            background: var(--surface-sub);
            color: var(--text-1);
            border-color: rgba(0, 0, 0, 0.15);
        }}
        .btn-sync.loading {{
            opacity: 0.75;
            pointer-events: none;
        }}
        @keyframes spin {{
            from {{ transform: rotate(0deg); }}
            to {{ transform: rotate(360deg); }}
        }}
        .spin-icon {{
            animation: spin 0.8s linear infinite;
        }}

        /* Hero Battery Card */
        .card-main {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 20px;
            padding: 26px 30px;
            margin-bottom: 24px;
            box-shadow: var(--card-shadow);
        }}
        .main-top {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 18px;
        }}
        .pct-group {{
            display: flex;
            align-items: center;
            gap: 14px;
        }}
        .pct-number {{
            font-size: 64px;
            font-weight: 700;
            letter-spacing: -2.5px;
            line-height: 1;
            color: var(--text-1);
            font-variant-numeric: tabular-nums;
        }}
        .status-capsule {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 12.5px;
            font-weight: 500;
        }}
        .capsule-charging {{
            background: rgba(52, 199, 89, 0.1);
            color: var(--apple-green);
        }}
        .capsule-hold {{
            background: rgba(0, 113, 227, 0.08);
            color: var(--apple-blue);
        }}
        .capsule-discharging {{
            background: rgba(0, 0, 0, 0.05);
            color: var(--text-2);
        }}
        @media (prefers-color-scheme: dark) {{
            .capsule-discharging {{
                background: rgba(255, 255, 255, 0.08);
                color: var(--text-2);
            }}
        }}
        .eta-group {{
            display: flex;
            flex-direction: column;
            align-items: flex-end;
            gap: 1px;
        }}
        .eta-label {{
            font-size: 11px;
            color: var(--text-3);
            font-weight: 500;
        }}
        .eta-val {{
            font-size: 14px;
            font-weight: 600;
            color: var(--text-1);
        }}

        /* Smooth Capsule Progress Bar */
        .battery-bar-track {{
            height: 8px;
            background: rgba(0, 0, 0, 0.05);
            border-radius: 100px;
            margin-bottom: 24px;
            overflow: hidden;
        }}
        @media (prefers-color-scheme: dark) {{
            .battery-bar-track {{
                background: rgba(255, 255, 255, 0.08);
            }}
        }}
        .battery-bar-fill {{
            height: 100%;
            background: linear-gradient(90deg, #34C759 0%, #30D158 100%);
            border-radius: 100px;
            transition: width 0.4s ease;
        }}

        /* Key Metrics Row */
        .stats-strip {{
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 18px;
            padding-top: 20px;
            border-top: 1px solid var(--border-sub);
        }}
        @media (max-width: 680px) {{
            .stats-strip {{ grid-template-columns: repeat(2, 1fr); }}
        }}
        .stat-item {{
            display: flex;
            flex-direction: column;
            gap: 3px;
        }}
        .st-label {{
            font-size: 11.5px;
            color: var(--text-3);
            font-weight: 500;
        }}
        .st-val {{
            font-size: 18.5px;
            font-weight: 600;
            letter-spacing: -0.5px;
            color: var(--text-1);
            font-variant-numeric: tabular-nums;
        }}
        .st-unit {{
            font-size: 13.5px;
            font-weight: 500;
            color: var(--text-3);
        }}
        .st-sub {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* Section Layouts */
        .section-wrap {{
            margin-bottom: 28px;
        }}
        .sec-head {{
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            margin-bottom: 12px;
            padding: 0 4px;
        }}
        .sec-title {{
            font-size: 13.5px;
            font-weight: 600;
            letter-spacing: -0.2px;
            color: var(--text-1);
        }}
        .sec-caption {{
            font-size: 11.5px;
            color: var(--text-3);
        }}

        /* Active Connection Card */
        .active-connection-card {{
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px 16px;
            background: rgba(52, 199, 89, 0.06);
            border: 1px solid rgba(52, 199, 89, 0.18);
            border-radius: 12px;
            margin-bottom: 14px;
        }}
        .conn-idle {{
            background: rgba(0, 0, 0, 0.03);
            border-color: var(--border);
        }}
        @media (prefers-color-scheme: dark) {{
            .conn-idle {{
                background: rgba(255, 255, 255, 0.03);
                border-color: var(--border-sub);
            }}
        }}
        .conn-icon-wrap {{
            width: 28px;
            height: 28px;
            border-radius: 50%;
            background: rgba(52, 199, 89, 0.15);
            color: var(--apple-green);
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
        }}
        .conn-icon-wrap.idle {{
            background: rgba(0, 0, 0, 0.06);
            color: var(--text-3);
        }}
        .conn-text {{
            display: flex;
            flex-direction: column;
            gap: 1px;
            flex: 1;
        }}
        .conn-title {{
            font-size: 12.5px;
            color: var(--text-1);
        }}
        .conn-spec {{
            font-size: 11.5px;
            color: var(--text-3);
        }}
        .conn-badge {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-size: 11.5px;
            color: var(--apple-green);
            font-weight: 500;
        }}
        .badge-idle {{
            color: var(--text-3);
        }}

        /* Power Flow 3-Cards Grid */
        .flow-grid {{
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 12px;
            margin-bottom: 14px;
        }}
        @media (max-width: 600px) {{
            .flow-grid {{ grid-template-columns: 1fr; }}
        }}
        .flow-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 16px 18px;
            display: flex;
            flex-direction: column;
            gap: 3px;
            box-shadow: var(--card-shadow);
        }}
        .fl-label {{
            font-size: 11.5px;
            color: var(--text-3);
            font-weight: 500;
        }}
        .fl-val-row {{
            display: flex;
            align-items: baseline;
            gap: 3px;
        }}
        .fl-val {{
            font-size: 24px;
            font-weight: 700;
            letter-spacing: -0.6px;
            color: var(--text-1);
            font-variant-numeric: tabular-nums;
        }}
        .fl-unit {{
            font-size: 14px;
            font-weight: 500;
            color: var(--text-3);
        }}
        .fl-sub {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* Power Split Meter */
        .flow-meter-container {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 14px 18px;
            margin-bottom: 16px;
            box-shadow: var(--card-shadow);
        }}
        .flow-meter-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 11.5px;
            color: var(--text-3);
            margin-bottom: 8px;
        }}
        .flow-meter-legend {{
            display: flex;
            align-items: center;
            gap: 12px;
        }}
        .leg-item {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
        }}
        .leg-dot {{
            width: 6px;
            height: 6px;
            min-width: 6px;
            min-height: 6px;
            aspect-ratio: 1 / 1;
            border-radius: 50%;
            flex-shrink: 0;
            display: inline-block;
        }}
        .dot-sys {{ background: var(--apple-blue); }}
        .dot-bat {{ background: var(--apple-green); }}

        .flow-meter-bar {{
            height: 7px;
            background: rgba(0, 0, 0, 0.05);
            border-radius: 100px;
            display: flex;
            overflow: hidden;
            gap: 2px;
        }}
        @media (prefers-color-scheme: dark) {{
            .flow-meter-bar {{ background: rgba(255, 255, 255, 0.08); }}
        }}
        .flow-seg-sys {{
            background: var(--apple-blue);
            height: 100%;
            border-radius: 100px 0 0 100px;
        }}
        .flow-seg-bat {{
            background: var(--apple-green);
            height: 100%;
            border-radius: 0 100px 100px 0;
        }}
        .power-warning {{
            background: rgba(255, 59, 48, 0.08);
            border: 1px solid rgba(255, 59, 48, 0.2);
            border-radius: 12px;
            padding: 12px 16px;
            color: var(--apple-red);
            font-size: 12px;
            line-height: 1.45;
            margin-bottom: 16px;
        }}

        /* Visual Hardware Port Schematic (Apple Chassis Aesthetic) */
        .hardware-schematic {{
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 16px;
        }}
        @media (max-width: 680px) {{
            .hardware-schematic {{ grid-template-columns: 1fr; }}
        }}
        .chassis-panel {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 18px 20px;
            box-shadow: var(--card-shadow);
        }}
        .chassis-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding-bottom: 12px;
            margin-bottom: 12px;
            border-bottom: 1px solid var(--border-sub);
        }}
        .chassis-title {{
            font-size: 12.5px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .chassis-badge {{
            font-size: 11px;
            padding: 2px 7px;
            border-radius: 100px;
            background: var(--surface-sub);
            color: var(--text-3);
            font-weight: 500;
        }}
        .port-list {{
            display: flex;
            flex-direction: column;
            gap: 8px;
        }}
        .port-chip {{
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 10px 12px;
            border-radius: 10px;
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            transition: all 0.15s ease;
        }}
        .port-chip:hover {{
            background: rgba(0, 0, 0, 0.03);
            border-color: rgba(0, 0, 0, 0.1);
        }}
        @media (prefers-color-scheme: dark) {{
            .port-chip:hover {{
                background: rgba(255, 255, 255, 0.04);
                border-color: rgba(255, 255, 255, 0.1);
            }}
        }}
        .port-chip-active {{
            background: rgba(52, 199, 89, 0.04) !important;
            border-color: rgba(52, 199, 89, 0.4) !important;
        }}
        .port-symbol {{
            width: 38px;
            height: 38px;
            border-radius: 10px;
            background: var(--surface-sub);
            border: 1px solid var(--border);
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            color: var(--text-1);
            transition: all 0.2s ease;
        }}
        .port-chip-active .port-symbol {{
            background: var(--apple-green) !important;
            color: #ffffff !important;
            border-color: transparent !important;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08) !important;
        }}
        .port-chip-info {{
            display: flex;
            flex-direction: column;
            gap: 2px;
            flex: 1;
        }}
        .port-chip-title-row {{
            display: flex;
            justify-content: space-between;
            align-items: center;
        }}
        .port-chip-name {{
            font-size: 13px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .port-chip-badge {{
            display: inline-flex;
            align-items: center;
            font-size: 11px;
            font-weight: 500;
            color: var(--apple-green);
            background: rgba(52, 199, 89, 0.08);
            border: 1px solid rgba(52, 199, 89, 0.2);
            padding: 2px 7px;
            border-radius: 100px;
            line-height: 1.2;
        }}
        .badge-dot {{
            width: 5px;
            height: 5px;
            min-width: 5px;
            min-height: 5px;
            aspect-ratio: 1 / 1;
            border-radius: 50%;
            background: var(--apple-green);
            display: inline-block;
            flex-shrink: 0;
            margin-right: 5px;
            vertical-align: middle;
        }}
        .port-chip-spec {{
            font-size: 11.5px;
            color: var(--text-3);
        }}

        /* App Table */
        .table-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 16px;
            overflow: hidden;
            box-shadow: var(--card-shadow);
        }}
        .app-table {{
            width: 100%;
            border-collapse: collapse;
            font-size: 12px;
        }}
        .app-table th {{
            text-align: left;
            padding: 10px 14px;
            font-size: 11px;
            color: var(--text-3);
            border-bottom: 1px solid var(--border);
            font-weight: 500;
            background: var(--surface-sub);
        }}
        .app-table td {{
            padding: 10px 14px;
            border-bottom: 1px solid var(--border-sub);
            vertical-align: middle;
        }}
        .app-table tr:last-child td {{
            border-bottom: none;
        }}
        .app-table tr:hover td {{
            background: rgba(0, 0, 0, 0.015);
        }}
        .td-app {{
            width: 38%;
        }}
        .app-cell {{
            display: flex;
            align-items: center;
            gap: 12px;
            min-width: 220px;
        }}
        .app-icon-badge {{
            width: 30px;
            height: 30px;
            border-radius: 8px;
            background: var(--surface-sub);
            border: 1px solid var(--border-sub);
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
        }}
        .app-meta {{
            display: flex;
            flex-direction: column;
            gap: 2px;
        }}
        .app-title {{
            font-size: 12.5px;
            font-weight: 600;
            color: var(--text-1);
            word-break: break-word;
            line-height: 1.3;
        }}
        .app-type {{
            font-size: 10.5px;
            color: var(--text-3);
        }}
        .td-mono {{
            color: var(--text-2);
            text-align: right;
            font-variant-numeric: tabular-nums;
        }}
        .td-proc {{
            color: var(--text-3);
        }}
        .td-status {{
            text-align: center;
            width: 60px;
        }}
        .status-badge {{
            display: inline-block;
            padding: 2px 7px;
            border-radius: 5px;
            font-size: 10.5px;
            font-weight: 500;
        }}
        .badge-low {{
            background: rgba(52, 199, 89, 0.12);
            color: #248a3d;
        }}
        .badge-mid {{
            background: rgba(255, 149, 0, 0.12);
            color: #c96d00;
        }}
        .badge-high {{
            background: rgba(255, 59, 48, 0.12);
            color: #d70015;
        }}
        @media (prefers-color-scheme: dark) {{
            .badge-low {{ color: #30D158; }}
            .badge-mid {{ color: #FF9F0A; }}
            .badge-high {{ color: #FF453A; }}
        }}
        .td-meter {{
            width: 90px;
        }}
        .meter-track {{
            width: 100%;
            height: 4px;
            background: rgba(0, 0, 0, 0.05);
            border-radius: 100px;
            overflow: hidden;
        }}
        @media (prefers-color-scheme: dark) {{
            .meter-track {{ background: rgba(255, 255, 255, 0.08); }}
        }}
        .meter-fill {{
            height: 100%;
            background: var(--apple-green);
            border-radius: 100px;
        }}

        /* Timeline Card */
        .timeline-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 18px 22px;
            box-shadow: var(--card-shadow);
        }}
        .tl-row {{
            display: flex;
            align-items: flex-start;
            gap: 14px;
            position: relative;
            padding-bottom: 12px;
        }}
        .tl-row:last-child {{
            padding-bottom: 0;
        }}
        .tl-row:not(:last-child)::after {{
            content: '';
            position: absolute;
            left: 69px;
            top: 13px;
            bottom: -2px;
            width: 1px;
            background: var(--border-sub);
        }}
        .tl-time {{
            font-size: 11px;
            color: var(--text-3);
            width: 58px;
            text-align: right;
            padding-top: 1px;
            font-variant-numeric: tabular-nums;
        }}
        .tl-indicator {{
            width: 15px;
            display: flex;
            justify-content: center;
            padding-top: 4px;
            z-index: 1;
        }}
        .tl-dot {{
            width: 6px;
            height: 6px;
            min-width: 6px;
            min-height: 6px;
            aspect-ratio: 1 / 1;
            border-radius: 50%;
            flex-shrink: 0;
            display: inline-block;
        }}
        .tl-content {{
            display: flex;
            flex-direction: column;
            gap: 1px;
            flex: 1;
        }}
        .tl-title {{
            font-size: 12px;
            font-weight: 600;
            color: var(--text-1);
        }}
        .tl-detail {{
            font-size: 11px;
            color: var(--text-3);
        }}

        /* Footer */
        footer {{
            margin-top: 32px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 11px;
            color: var(--text-3);
            border-top: 1px solid var(--border-sub);
            padding-top: 14px;
        }}
        .footer-brand {{
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-weight: 500;
        }}
    </style>
</head>
<body>
    <div class="shell">
        <header>
            <div class="header-left">
                <div class="brand-icon-wrap">
                    {dynamic_battery_svg}
                </div>
                <div class="device-info">
                    <div class="device-name-row">
                        <span class="device-name">MacBook Pro 14″</span>
                        <span class="live-pill">
                            <span class="pulse-dot"></span>
                            <span id="live-clock">{data['generated_at']}</span>
                        </span>
                        <span class="app-version-pill" onclick="triggerCheckUpdate()" title="Nhấn để kiểm tra cập nhật BatFlow">v1.0.1</span>
                    </div>
                    <span class="device-chip">Apple M1 Pro • Bộ nhớ 16 GB</span>
                </div>
            </div>
            <div class="header-actions">
                <button class="btn-action-update" id="btn-update" onclick="triggerCheckUpdate()" title="Kiểm tra phiên bản mới BatFlow">
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                    Bản mới
                </button>
                <button class="btn-sync" id="btn-sync" onclick="triggerRefresh()">
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/></svg>
                    Làm mới
                </button>
            </div>
        </header>

        <!-- Primary Status Card -->
        <div class="card-main">
            <div class="main-top">
                <div class="pct-group">
                    <span class="pct-number">{data['percent']}%</span>
                    <div id="hero-status-capsule" class="status-capsule {status_theme_class}">
                        <span id="hero-status-icon">{status_icon}</span>
                        <span id="hero-status-text">{data['state_str']}</span>
                    </div>
                </div>
                <div class="eta-group">
                    <span class="eta-label">Dự kiến {eta_title}</span>
                    <span class="eta-val">{data['time_remaining']}</span>
                </div>
            </div>

            <div class="battery-bar-track">
                <div class="battery-bar-fill" style="width: {data['percent']}%;"></div>
            </div>

            <div class="stats-strip">
                <div class="stat-item">
                    <span class="st-label">Onscreen đợt này</span>
                    <span class="st-val" id="session-time">{data['session_screen_time']}</span>
                    <span class="st-sub">Từ lúc mở ({data['session_start_time']})</span>
                </div>
                <div class="stat-item">
                    <span class="st-label">Tổng onscreen hôm nay</span>
                    <span class="st-val" id="total-time">{data['total_screen_time']}</span>
                    <span class="st-sub">Tích lũy cả ngày</span>
                </div>
                <div class="stat-item">
                    <span class="st-label">Công suất máy dùng</span>
                    <span class="st-val">{data['sys_load_w']} <span class="st-unit">W</span></span>
                    <span class="st-sub">{data['voltage']} V • {abs(data['amperage'])} mA</span>
                </div>
                <div class="stat-item">
                    <span class="st-label">Sức khỏe pin (Apple)</span>
                    <span class="st-val">{data['apple_health_pct']}%</span>
                    <span class="st-sub">Đo thô cell: {data['raw_health_pct']}%</span>
                </div>
            </div>
        </div>

        <!-- Section 2: Realtime Power Flow & Charging Delivery -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Phân bổ điện năng & nguồn sạc</span>
                <span class="sec-caption">Giám sát dòng nạp sạc và công suất máy dùng</span>
            </div>

            {power_flow_html}

            <!-- Hardware Port Schematic (Apple Chassis Aesthetic) -->
            <div class="hardware-schematic">
                <!-- Left Edge Panel -->
                <div class="chassis-panel">
                    <div class="chassis-header">
                        <span class="chassis-title">Cạnh trái máy (Từ bản lề ra trước)</span>
                        <span class="chassis-badge">3 cổng tiếp điện</span>
                    </div>
                    <div class="port-list">
                        <!-- Port 1: MagSafe 3 -->
                        <div id="port-chip-magsafe" class="port-chip {active_class_magsafe}">
                            <div class="port-symbol">
                                <svg width="20" height="20" viewBox="0 0 16 16" fill="currentColor">
                                    <path d="M11.251.068a.5.5 0 0 1 .227.58L9.677 6.5H13a.5.5 0 0 1 .364.843l-8 8.5a.5.5 0 0 1-.842-.49L6.323 9.5H3a.5.5 0 0 1-.364-.843l8-8.5a.5.5 0 0 1 .615-.09z"/>
                                </svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">1. Cổng MagSafe 3 (Sát bản lề)</span>
                                    {active_tag_magsafe}
                                </div>
                                <span class="port-chip-spec">Sạc nhanh 96W • Chuẩn từ tính Apple MagSafe 3 (Chỉ nhận nguồn sạc vào)</span>
                            </div>
                        </div>

                        <!-- Port 2: Type-C 1 -->
                        <div id="port-chip-left-c1" class="port-chip {active_class_left_c1}">
                            <div class="port-symbol">
                                <svg width="22" height="22" viewBox="0 0 16 16" fill="currentColor">
                                    <path d="M3.5 7.5a.5.5 0 0 0 0 1h9a.5.5 0 0 0 0-1z"/>
                                    <path d="M0 8a3 3 0 0 1 3-3h10a3 3 0 1 1 0 6H3a3 3 0 0 1-3-3m3-2a2 2 0 1 0 0 4h10a2 2 0 1 0 0-4z"/>
                                </svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">2. Cổng Type-C / Thunderbolt 4 (Vị trí giữa)</span>
                                    {active_tag_left_c1}
                                </div>
                                <span class="port-chip-spec">TB4 (40 Gbps) • Vào: Sạc PD 100W • Ra: Cấp nguồn 15W, Xuất hình 6K 60Hz</span>
                            </div>
                        </div>

                        <!-- Port 3: Type-C 2 -->
                        <div id="port-chip-left-c2" class="port-chip {active_class_left_c2}">
                            <div class="port-symbol">
                                <svg width="22" height="22" viewBox="0 0 16 16" fill="currentColor">
                                    <path d="M3.5 7.5a.5.5 0 0 0 0 1h9a.5.5 0 0 0 0-1z"/>
                                    <path d="M0 8a3 3 0 0 1 3-3h10a3 3 0 1 1 0 6H3a3 3 0 0 1-3-3m3-2a2 2 0 1 0 0 4h10a2 2 0 1 0 0-4z"/>
                                </svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">3. Cổng Type-C / Thunderbolt 4 (Phía trước)</span>
                                    {active_tag_left_c2}
                                </div>
                                <span class="port-chip-spec">TB4 (40 Gbps) • Vào: Sạc PD 100W • Ra: Cấp nguồn 15W, Xuất hình 6K 60Hz</span>
                            </div>
                        </div>

                        <!-- Port 4: 3.5mm Headphone Jack -->
                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                    <path d="M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3"/>
                                </svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">4. Jack âm thanh 3.5mm</span>
                                </div>
                                <span class="port-chip-spec">Đầu ra âm thanh analog • Tự nhận diện tai nghe trở kháng cao</span>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Right Edge Panel -->
                <div class="chassis-panel">
                    <div class="chassis-header">
                        <span class="chassis-title">Cạnh phải máy (Từ bản lề ra trước)</span>
                        <span class="chassis-badge">1 cổng tiếp điện</span>
                    </div>
                    <div class="port-list">
                        <!-- Port 1: HDMI 2.0 -->
                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="22" height="22" viewBox="0 0 16 16" fill="currentColor">
                                    <path d="M2.5 7a.5.5 0 0 0 0 1h11a.5.5 0 0 0 0-1z"/>
                                    <path d="M1 5a1 1 0 0 0-1 1v3a1 1 0 0 0 1 1h.293l.707.707a1 1 0 0 0 .707.293h10.586a1 1 0 0 0 .707-.293l.707-.707H15a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1zm0 1h14v3h-.293a1 1 0 0 0-.707.293l-.707.707H2.707L2 9.293A1 1 0 0 0 1.293 9H1z"/>
                                </svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">1. Cổng HDMI 2.0 (Sát bản lề)</span>
                                </div>
                                <span class="port-chip-spec">Đầu ra xuất hình: Chuẩn HDMI 2.0 hỗ trợ 4K 60Hz & Âm thanh đa kênh</span>
                            </div>
                        </div>

                        <!-- Port 2: Type-C Right -->
                        <div id="port-chip-right-c" class="port-chip {active_class_right_c}">
                            <div class="port-symbol">
                                <svg width="22" height="22" viewBox="0 0 16 16" fill="currentColor">
                                    <path d="M3.5 7.5a.5.5 0 0 0 0 1h9a.5.5 0 0 0 0-1z"/>
                                    <path d="M0 8a3 3 0 0 1 3-3h10a3 3 0 1 1 0 6H3a3 3 0 0 1-3-3m3-2a2 2 0 1 0 0 4h10a2 2 0 1 0 0-4z"/>
                                </svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">2. Cổng Type-C / Thunderbolt 4 (Ở giữa)</span>
                                    {active_tag_right_c}
                                </div>
                                <span class="port-chip-spec">TB4 (40 Gbps) • Vào: Sạc PD 100W • Ra: Cấp nguồn 15W, Xuất hình 6K 60Hz</span>
                            </div>
                        </div>

                        <!-- Port 3: SD Card Slot -->
                        <div class="port-chip">
                            <div class="port-symbol">
                                <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                    <path d="M7 21h10a2 2 0 0 0 2 -2v-14a2 2 0 0 0 -2 -2h-6.172a2 2 0 0 0 -1.414 .586l-3.828 3.828a2 2 0 0 0 -.586 1.414v10.172a2 2 0 0 0 2 2"/>
                                    <path d="M13 6v2"/>
                                    <path d="M16 6v2"/>
                                    <path d="M10 7v1"/>
                                </svg>
                            </div>
                            <div class="port-chip-info">
                                <div class="port-chip-title-row">
                                    <span class="port-chip-name">3. Khe cắm thẻ nhớ SDXC (Trước)</span>
                                </div>
                                <span class="port-chip-spec">Chuẩn UHS-II tốc độ cao 312 MB/s (Truyền dữ liệu, không tiếp điện)</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Section 3: Top Power Consumers -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Ứng dụng tiêu thụ năng lượng</span>
                <span class="sec-caption">Sắp xếp theo mức độ tải CPU và bộ nhớ RAM</span>
            </div>

            <div class="table-card">
                <table class="app-table">
                    <thead>
                        <tr>
                            <th>Ứng dụng</th>
                            <th style="text-align: right;">Tải CPU</th>
                            <th style="text-align: right;">Bộ nhớ RAM</th>
                            <th style="text-align: right;">Số luồng</th>
                            <th style="text-align: center;">Đánh giá</th>
                            <th style="text-align: right;">Mức độ tải</th>
                        </tr>
                    </thead>
                    <tbody>
                        {app_rows}
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Section 4: Recent Timeline -->
        <div class="section-wrap">
            <div class="sec-head">
                <span class="sec-title">Nhật ký trạng thái gần đây</span>
                <span class="sec-caption">Lịch sử sự kiện nguồn điện & hoạt động</span>
            </div>

            <div class="timeline-card">
                {timeline_rows}
            </div>
        </div>

        <footer>
            <span class="footer-brand">● BatFlow • Tulie Tech</span>
            <span>Cập nhật gần nhất lúc {data['generated_at']}</span>
        </footer>
    </div>

    <script>
        let sessSec = {data['session_on_sec']};
        let totalSec = {data['total_screen_sec']};

        function formatHMS(sec) {{
            const h = Math.floor(sec / 3600);
            const m = Math.floor((sec % 3600) / 60);
            const s = sec % 60;
            return `${{h}}h : ${{String(m).padStart(2, '0')}}m : ${{String(s).padStart(2, '0')}}s`;
        }}

        // Auto preserve & restore scroll position seamlessly across reloads
        (function() {{
            const scrollKey = 'batflow_scroll_y';
            const saved = sessionStorage.getItem(scrollKey);
            if (saved !== null) {{
                const y = parseInt(saved, 10);
                if (!isNaN(y) && y > 0) {{
                    window.scrollTo(0, y);
                    requestAnimationFrame(() => {{
                        window.scrollTo(0, y);
                    }});
                }}
            }}
            window.addEventListener('scroll', () => {{
                sessionStorage.setItem(scrollKey, window.scrollY);
            }}, {{ passive: true }});
        }})();

        function triggerCheckUpdate() {{
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.batflow) {{
                window.webkit.messageHandlers.batflow.postMessage({{ action: "checkUpdate" }});
            }}
        }}

        function triggerRefresh() {{
            const btn = document.getElementById('btn-sync');
            if (btn) {{
                btn.classList.add('loading');
                btn.innerHTML = '<svg class="spin-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/></svg> Đang làm mới...';
            }}
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.batflow) {{
                window.webkit.messageHandlers.batflow.postMessage({{ action: "refresh" }});
            }} else {{
                location.reload();
            }}
        }}
        window.setRefreshLoading = function(isLoading) {{
            const btn = document.getElementById('btn-sync');
            if (!btn) return;
            if (isLoading) {{
                btn.classList.add('loading');
                btn.innerHTML = '<svg class="spin-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/></svg> Đang làm mới...';
            }}
        }};

        window.applyPowerState = function(state) {{
            const magsafeChip = document.getElementById('port-chip-magsafe');
            const magsafeTag = document.getElementById('port-tag-magsafe');
            const c1Chip = document.getElementById('port-chip-left-c1');
            const c1Tag = document.getElementById('port-tag-left-c1');
            const heroStatus = document.getElementById('hero-status-capsule');
            const heroText = document.getElementById('hero-status-text');
            const heroPct = document.querySelector('.pct-number');
            const batFill = document.querySelector('.battery-bar-fill');
            
            if (heroPct && state.percent) heroPct.innerText = state.percent + '%';
            if (batFill && state.percent) batFill.style.width = state.percent + '%';

            if (state.isExtConnected) {{
                if (state.isMagSafe) {{
                    if (magsafeChip) magsafeChip.classList.add('port-chip-active');
                    if (magsafeTag) magsafeTag.style.display = 'inline-flex';
                    if (c1Chip) c1Chip.classList.remove('port-chip-active');
                    if (c1Tag) c1Tag.style.display = 'none';
                }} else {{
                    if (c1Chip) c1Chip.classList.add('port-chip-active');
                    if (c1Tag) c1Tag.style.display = 'inline-flex';
                    if (magsafeChip) magsafeChip.classList.remove('port-chip-active');
                    if (magsafeTag) magsafeTag.style.display = 'none';
                }}
                if (heroStatus) {{
                    heroStatus.className = 'status-capsule ' + (state.isCharging ? 'status-charging' : 'status-discharging');
                    if (heroText) {{
                        if (state.isCharging) {{
                            heroText.innerText = 'Đang sạc pin';
                        }} else {{
                            heroText.innerText = (state.percent >= 99) ? 'Nguồn điện Adapter (Đầy)' : 'Nguồn Adapter (Tạm dừng sạc)';
                        }}
                    }}
                }}
            }} else {{
                if (magsafeChip) magsafeChip.classList.remove('port-chip-active');
                if (magsafeTag) magsafeTag.style.display = 'none';
                if (c1Chip) c1Chip.classList.remove('port-chip-active');
                if (c1Tag) c1Tag.style.display = 'none';
                if (heroStatus) {{
                    heroStatus.className = 'status-capsule status-discharging';
                    if (heroText) heroText.innerText = 'Đang dùng pin (Xả pin)';
                }}
            }}
        }};

        setInterval(() => {{
            sessSec += 1;
            totalSec += 1;

            const elSess = document.getElementById('session-time');
            const elTotal = document.getElementById('total-time');
            if (elSess) elSess.innerText = formatHMS(sessSec);
            if (elTotal) elTotal.innerText = formatHMS(totalSec);

            const clockEl = document.getElementById('live-clock');
            if (clockEl) {{
                const now = new Date();
                clockEl.innerText = now.toTimeString().split(' ')[0];
            }}
        }}, 1000);
    </script>
</body>
</html>
"""
    return html_out

def main():
    report_path = None
    custom_health = None
    if len(sys.argv) > 1 and sys.argv[1]:
        report_path = sys.argv[1]
    else:
        app_support = os.path.expanduser('~/Library/Application Support/BatFlow')
        os.makedirs(app_support, exist_ok=True)
        report_path = os.path.join(app_support, 'battery_report.html')

    if len(sys.argv) > 2 and sys.argv[2]:
        try:
            custom_health = int(sys.argv[2])
        except:
            pass
    
    data = get_battery_and_processes(custom_apple_health=custom_health)
    html_content = generate_html(data)
    
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write(html_content)
    try:
        os.chmod(report_path, 0o600)
    except:
        pass

if __name__ == '__main__':
    main()
