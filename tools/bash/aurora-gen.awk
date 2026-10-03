# Deterministic generator shared with tools/ps/native/AuroraGen.cs.
# 64-bit arithmetic uses 16-bit limbs so it stays exact in IEEE doubles.
# Run under LC_ALL=C so text is bytes.

function fail(msg) { print msg > "/dev/stderr"; exit 1 }
function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function hexdig(n) { return substr("0123456789abcdef", n + 1, 1) }
function twopow(n,    v, i) { v = 1; for (i = 0; i < n; i++) v *= 2; return v }
function u_norm(h,    i, s) {
    h = tolower(h)
    s = ""
    for (i = length(h) + 1; i <= 16; i++) s = s "0"
    return s h
}
function hex4(s,    v, k) {
    v = 0
    for (k = 1; k <= length(s); k++) v = v * 16 + hexval(substr(s, k, 1))
    return v
}
function u_get(h, i,    s) {
    s = u_norm(h)
    return hex4(substr(s, 13 - 4 * i, 4))
}
function u_put(L,    i, s) {
    s = ""
    for (i = 3; i >= 0; i--) s = s sprintf("%04x", (L[i] + 0) % 65536)
    return s
}
function u_add(a, b,    R, i, t, carry) {
    carry = 0
    for (i = 0; i < 4; i++) {
        t = u_get(a, i) + u_get(b, i) + carry
        R[i] = t % 65536
        carry = int(t / 65536)
    }
    return u_put(R)
}
function u_sub(a, b,    R, i, t, borrow) {
    borrow = 0
    for (i = 0; i < 4; i++) {
        t = u_get(a, i) - u_get(b, i) - borrow
        if (t < 0) { t += 65536; borrow = 1 } else borrow = 0
        R[i] = t
    }
    return u_put(R)
}
function u_mul(a, b,    A, B, R, i, j, t, carry) {
    for (i = 0; i < 4; i++) { A[i] = u_get(a, i); B[i] = u_get(b, i); R[i] = 0 }
    for (i = 0; i < 4; i++) {
        carry = 0
        for (j = 0; j < 4 - i; j++) {
            t = R[i + j] + A[i] * B[j] + carry
            R[i + j] = t % 65536
            carry = int(t / 65536)
        }
    }
    return u_put(R)
}
function u_xor(a, b,    R, i, x, y, k, bit, r) {
    for (i = 0; i < 4; i++) {
        x = u_get(a, i); y = u_get(b, i); r = 0
        for (k = 0; k < 16; k++) {
            bit = twopow(k)
            if (int(x / bit) % 2 != int(y / bit) % 2) r += bit
        }
        R[i] = r
    }
    return u_put(R)
}
function u_cmp(a, b,    x, y) {
    x = u_norm(a); y = u_norm(b)
    if (x == y) return 0
    return (x > y) ? 1 : -1
}
function u_shr(a, k,    A, R, i, n, base, src, val) {
    if (k <= 0) return u_norm(a)
    if (k >= 64) return "0000000000000000"
    for (i = 0; i < 4; i++) A[i] = u_get(a, i)
    n = k % 16
    base = int(k / 16)
    for (i = 0; i < 4; i++) {
        src = i + base
        val = 0
        if (src < 4) val = int(A[src] / twopow(n))
        if (n > 0 && src + 1 < 4) val += (A[src + 1] % twopow(n)) * twopow(16 - n)
        R[i] = val % 65536
    }
    return u_put(R)
}
function u_shl(a, k,    A, R, i, n, base, src, val) {
    if (k <= 0) return u_norm(a)
    if (k >= 64) return "0000000000000000"
    for (i = 0; i < 4; i++) A[i] = u_get(a, i)
    n = k % 16
    base = int(k / 16)
    for (i = 0; i < 4; i++) {
        src = i - base
        val = 0
        if (src >= 0) val = (A[src] * twopow(n)) % 65536
        if (n > 0 && src - 1 >= 0) val += int(A[src - 1] / twopow(16 - n))
        R[i] = val % 65536
    }
    return u_put(R)
}
function ge5(A, B,    i) {
    for (i = 4; i >= 0; i--) {
        if (A[i] > B[i]) return 1
        if (A[i] < B[i]) return 0
    }
    return 1
}
function sub5(A, B,    i, t, borrow) {
    borrow = 0
    for (i = 0; i < 5; i++) {
        t = A[i] - B[i] - borrow
        if (t < 0) { t += 65536; borrow = 1 } else borrow = 0
        A[i] = t
    }
}
function u_divmod(n, d,    N, D, R, Q, bit, limb, mask, j, t, carry) {
    if (u_norm(d) == "0000000000000000") fail("division by zero")
    for (j = 0; j < 5; j++) { R[j] = 0; D[j] = 0; Q[j] = 0; N[j] = 0 }
    for (j = 0; j < 4; j++) { N[j] = u_get(n, j); D[j] = u_get(d, j) }
    for (bit = 63; bit >= 0; bit--) {
        carry = 0
        for (j = 0; j < 5; j++) {
            t = R[j] * 2 + carry
            R[j] = t % 65536
            carry = int(t / 65536)
        }
        limb = int(bit / 16)
        mask = twopow(bit % 16)
        if (int(N[limb] / mask) % 2 == 1) {
            R[0]++
            j = 0
            while (R[j] >= 65536) { R[j] -= 65536; j++; R[j]++ }
        }
        if (ge5(R, D)) { sub5(R, D); Q[limb] += mask }
    }
    U_MOD = u_put(R)
    return u_put(Q)
}
function dec_norm(s) { sub(/^0+/, "", s); if (s == "") return "0"; return s }
function dec_cmp(a, b) {
    a = dec_norm(a); b = dec_norm(b)
    if (length(a) != length(b)) return (length(a) > length(b)) ? 1 : -1
    if (a == b) return 0
    return (a > b) ? 1 : -1
}
function dec_add(a, b,    i, carry, da, db, t, s) {
    a = dec_norm(a); b = dec_norm(b); carry = 0; s = ""; i = 0
    while (i < length(a) || i < length(b) || carry) {
        da = 0; db = 0
        if (i < length(a)) da = substr(a, length(a) - i, 1) + 0
        if (i < length(b)) db = substr(b, length(b) - i, 1) + 0
        t = da + db + carry
        s = (t % 10) s
        carry = int(t / 10)
        i++
    }
    return dec_norm(s)
}
function dec_mul(a, b,    digs, i, j, n, m, da, db, t, carry, s) {
    a = dec_norm(a); b = dec_norm(b); n = length(a); m = length(b)
    for (i = 0; i < n + m + 1; i++) digs[i] = 0
    for (i = 0; i < n; i++) {
        carry = 0
        da = substr(a, n - i, 1) + 0
        for (j = 0; j < m; j++) {
            db = substr(b, m - j, 1) + 0
            t = digs[i + j] + da * db + carry
            digs[i + j] = t % 10
            carry = int(t / 10)
        }
        digs[i + m] += carry
    }
    s = ""
    for (i = n + m; i >= 0; i--) s = s digs[i]
    return dec_norm(s)
}
function u_from_dec(s,    h, i) {
    if (s ~ /[^0-9]/) fail("not an unsigned integer: " s)
    if (dec_cmp(s, "18446744073709551615") > 0) fail("integer does not fit in 64 bits: " s)
    h = "0000000000000000"
    for (i = 1; i <= length(s); i++) {
        h = u_mul(h, "000000000000000a")
        h = u_add(h, sprintf("%016x", substr(s, i, 1) + 0))
    }
    return h
}
function u_to_dec(h,    s, q) {
    h = u_norm(h)
    if (h == "0000000000000000") return "0"
    s = ""
    while (h != "0000000000000000") {
        q = u_divmod(h, "000000000000000a")
        s = sprintf("%d", u_get(U_MOD, 0)) s
        h = q
    }
    return s
}
function rng_init(seed_hex) {
    seed_hex = u_norm(seed_hex)
    if (seed_hex == "0000000000000000") seed_hex = "9e3779b97f4a7c15"
    RNG = seed_hex
}
function rng_next(    x) {
    x = RNG
    x = u_xor(x, u_shr(x, 12))
    x = u_xor(x, u_shl(x, 25))
    x = u_xor(x, u_shr(x, 27))
    RNG = x
    return u_mul(x, "2545f4914f6cdd1d")
}
function rng_bounded(bound,    maxv, rem, limit, r, guard) {
    bound = u_norm(bound)
    if (bound == "0000000000000000") fail("bound is 0")
    if (bound == "0000000000000001") return "0000000000000000"
    maxv = "ffffffffffffffff"
    rem = u_divmod(maxv, bound)
    rem = U_MOD
    limit = u_sub(maxv, rem)
    guard = 0
    do {
        r = rng_next()
        guard++
        if (guard > 10000) fail("rng rejection did not finish")
    } while (u_cmp(r, limit) >= 0)
    return u_divmod(r, bound) == "" ? "" : U_MOD
}
function rng_bounded_dec(bound_dec) {
    if (dec_cmp(bound_dec, "0") <= 0) fail("bound is 0")
    if (dec_cmp(bound_dec, "1") == 0) return "0"
    if (dec_cmp(bound_dec, "18446744073709551615") > 0) fail("range wider than 64 bits is supported by the PowerShell generator")
    return u_to_dec(rng_bounded(u_from_dec(bound_dec)))
}
function draw_index(count) { return rng_bounded_dec(sprintf("%d", count)) + 0 }
function fnv_mix(seed_dec, text,    h, i, b) {
    h = "cbf29ce484222325"
    h = u_xor(h, u_from_dec(seed_dec))
    h = u_mul(h, "00000100000001b3")
    for (i = 1; i <= length(text); i++) {
        b = ord(substr(text, i, 1))
        if (b < 0) fail("cannot mix non-byte text")
        h = u_xor(h, sprintf("%016x", b))
        h = u_mul(h, "00000100000001b3")
    }
    if (h == "0000000000000000") h = "9e3779b97f4a7c15"
    return splitmix(h)
}
function splitmix(z) {
    z = u_add(z, "9e3779b97f4a7c15")
    z = u_mul(u_xor(z, u_shr(z, 30)), "bf58476d1ce4e5b9")
    z = u_mul(u_xor(z, u_shr(z, 27)), "94d049bb133111eb")
    return u_xor(z, u_shr(z, 31))
}
function ord(c) {
    if (length(c) != 1) return -1
    if (c == sprintf("%c", 0)) return 0
    if (!(c in ORDV)) return -1
    return ORDV[c]
}
function init_ord(    i) { for (i = 1; i <= 255; i++) ORDV[sprintf("%c", i)] = i }
function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
function csv_field(s, isnull,    i, c, o, b) {
    if (isnull) return "\\N"
    o = "\""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        b = ord(c)
        if (c == "\\" || c == "\"") o = o "\\" c
        else if (c == "\n") o = o "\\n"
        else if (c == "\r") o = o "\\r"
        else if (b == 0) o = o "\\0"
        else if (b == 26) o = o "\\Z"
        else o = o c
    }
    return o "\""
}
function seq_digits(start, step, row, pad,    v) {
    if (start == "") start = "1"
    if (step == "") step = "1"
    v = dec_add(start, dec_mul(row, step))
    while ((pad + 0) > length(v)) v = "0" v
    return v
}
function to_units(text, scale,    sign, dot, whole, frac, digits) {
    sign = ""
    if (substr(text, 1, 1) == "-") fail("negative ranges are supported by the PowerShell generator")
    dot = index(text, ".")
    if (dot == 0) { whole = text; frac = "" } else { whole = substr(text, 1, dot - 1); frac = substr(text, dot + 1) }
    if (whole == "") whole = "0"
    while (length(frac) < scale) frac = frac "0"
    if (length(frac) > scale) fail("too many decimal places: " text)
    digits = dec_norm(whole frac)
    return digits
}
function format_units(units, scale,    u, whole, frac) {
    if ((scale + 0) <= 0) return dec_norm(units)
    u = dec_norm(units)
    while (length(u) <= (scale + 0)) u = "0" u
    whole = substr(u, 1, length(u) - scale)
    frac = substr(u, length(u) - scale + 1, scale)
    return whole "." frac
}
function is_leap(y) { return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) }
function date_days(y, m, d,    yy, md) {
    if (is_leap(y)) split("0 31 60 91 121 152 182 213 244 274 305 335", md, " ")
    else split("0 31 59 90 120 151 181 212 243 273 304 334", md, " ")
    yy = y - 1
    return yy * 365 + int(yy / 4) - int(yy / 100) + int(yy / 400) + (md[m] + 0) + d - 1
}
function when_ticks(y, m, d, h, mi, s,    dayt, sec, timet) {
    dayt = u_mul(sprintf("%016x", date_days(y, m, d)), u_from_dec("864000000000"))
    sec = ((h * 60 + mi) * 60 + s)
    timet = u_mul(sprintf("%016x", sec), u_from_dec("10000000"))
    return u_add(dayt, timet)
}
function floor_ticks(ticks, step,    q) {
    q = u_divmod(ticks, step)
    return u_mul(q, step)
}
function ceil_ticks(ticks, step,    f) {
    f = floor_ticks(ticks, step)
    if (f == u_norm(ticks)) return f
    return u_add(f, step)
}
function ymd_from_days(n,    lo, hi, mid, start, doy, month, dim) {
    lo = 1; hi = 9999
    while (lo < hi) {
        mid = int((lo + hi + 1) / 2)
        start = date_days(mid, 1, 1)
        if (start <= n) lo = mid
        else hi = mid - 1
    }
    Y = lo
    doy = n - date_days(Y, 1, 1)
    for (month = 1; month <= 12; month++) {
        dim = 31
        if (month == 4 || month == 6 || month == 9 || month == 11) dim = 30
        if (month == 2) dim = is_leap(Y) ? 29 : 28
        if (doy < dim) { M = month; D = doy + 1; return }
        doy -= dim
    }
    fail("could not convert ticks to a date")
}
function format_when(ticks, dt,    sec, sod, h, mi, s) {
    sec = u_to_dec(u_divmod(ticks, u_from_dec("10000000"))) + 0
    ymd_from_days(int(sec / 86400))
    sod = sec % 86400
    h = int(sod / 3600); mi = int((sod % 3600) / 60); s = sod % 60
    if (dt == "date") return sprintf("%04d-%02d-%02d", Y, M, D)
    if (dt == "time") return sprintf("%02d:%02d:%02d", h, mi, s)
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d", Y, M, D, h, mi, s)
}
function parse_when_ticks(text, dt,    y, m, d, h, mi, s) {
    if (dt == "time") {
        h = substr(text, 1, 2) + 0; mi = substr(text, 4, 2) + 0; s = substr(text, 7, 2) + 0
        return when_ticks(1, 1, 1, h, mi, s)
    }
    y = substr(text, 1, 4) + 0; m = substr(text, 6, 2) + 0; d = substr(text, 9, 2) + 0
    h = 0; mi = 0; s = 0
    if (dt != "date" && length(text) >= 19) {
        h = substr(text, 12, 2) + 0; mi = substr(text, 15, 2) + 0; s = substr(text, 18, 2) + 0
    }
    return when_ticks(y, m, d, h, mi, s)
}
function date_value(mintext, maxtext, dt, precision,    a, b, step, start, end, steps, add, i) {
    a = parse_when_ticks(mintext, dt)
    b = parse_when_ticks(maxtext, dt)
    step = u_from_dec("10000000")
    for (i = 0; i < (precision + 0); i++) step = u_divmod(step, u_from_dec("10"))
    start = ceil_ticks(a, step)
    end = floor_ticks(b, step)
    if (u_cmp(end, start) < 0) end = start
    steps = dec_add(u_to_dec(u_divmod(u_sub(end, start), step)), "1")
    if (steps == "1") add = "0"
    else add = rng_bounded_dec(steps)
    return format_when(u_add(start, u_mul(step, u_from_dec(add))), dt)
}
function make_uuid(seed, table, column, row,    salt, n, h, v) {
    salt = fnv_mix(seed, table "\n" column)
    n = u_from_dec(dec_add(row, "1"))
    h = salt n
    h = substr(h, 1, 12) "4" substr(h, 14)
    v = hexval(substr(h, 17, 1))
    v = (v % 4) + 8
    h = substr(h, 1, 16) hexdig(v) substr(h, 18)
    return substr(h, 1, 8) "-" substr(h, 9, 4) "-" substr(h, 13, 4) "-" substr(h, 17, 4) "-" substr(h, 21, 12)
}
function eval_pattern(pat,    i, c, out) {
    out = ""; i = 1
    while (i <= length(pat)) {
        c = substr(pat, i, 1)
        if (c == "\\" && i < length(pat)) { out = out substr(pat, i + 1, 1); i += 2; continue }
        if (c == "#") out = out substr(DIGITS, draw_index(10) + 1, 1)
        else if (c == "A") out = out substr(UPPER, draw_index(26) + 1, 1)
        else if (c == "a") out = out substr(LOWER, draw_index(26) + 1, 1)
        else if (c == "X") out = out substr(ALNUM, draw_index(62) + 1, 1)
        else out = out c
        i++
    }
    return out
}
function eval_token(token, start, step, row, seed, table, column,    p, kind, arg, n, i, alphabet, s, m, items) {
    p = index(token, ":")
    if (p == 0) { kind = token; arg = "" } else { kind = substr(token, 1, p - 1); arg = substr(token, p + 1) }
    if (kind == "seq") return seq_digits(start, step, row, arg == "" ? 0 : arg + 0)
    if (kind == "uuid") return make_uuid(seed, table, column, row)
    if (kind == "rand") {
        n = (arg == "" ? 1000000 : arg + 0)
        if (n <= 0) n = 1
        return rng_bounded_dec(sprintf("%d", n))
    }
    if (kind == "alpha" || kind == "digit" || kind == "hex") {
        n = arg + 0
        alphabet = (kind == "alpha" ? UPPER LOWER : (kind == "digit" ? DIGITS : HEXL))
        s = ""
        for (i = 0; i < n; i++) s = s substr(alphabet, draw_index(length(alphabet)) + 1, 1)
        return s
    }
    if (kind == "choice") {
        m = split_pipes(arg, items)
        if (m <= 0) fail("empty choice")
        return items[draw_index(m) + 1]
    }
    fail("bad template token " token)
}
function eval_template(tmpl, start, step, row, seed, table, column,    i, c, rest, end, token, out) {
    out = ""; i = 1
    while (i <= length(tmpl)) {
        c = substr(tmpl, i, 1)
        if (c != "{") { out = out c; i++; continue }
        rest = substr(tmpl, i + 1)
        end = index(rest, "}")
        if (end == 0) fail("bad template")
        token = substr(rest, 1, end - 1)
        out = out eval_token(token, start, step, row, seed, table, column)
        i = i + end + 1
    }
    return out
}
function split_pipes(text, out,    n, i, p, m, parts) {
    n = split(text, parts, "|"); m = 0
    for (i = 1; i <= n; i++) {
        p = trim(parts[i])
        if (p == "") continue
        if (p == "$EMPTY$") p = ""
        m++; out[m] = p
    }
    return m
}
function col(c, k) { return ( (c SUBSEP k) in COL ? COL[c, k] : "" ) }
function setcol(c, k, v) { COL[c, k] = v }
function yes(v) { v = toupper(v); return (v == "YES" || v == "Y" || v == "TRUE" || v == "1") }
function is_int(dt) { return (dt == "tinyint" || dt == "smallint" || dt == "mediumint" || dt == "int" || dt == "integer" || dt == "bigint") }
function is_decimal(dt) { return (dt == "decimal" || dt == "numeric" || dt == "float" || dt == "double" || dt == "real") }
function is_string(dt) { return (dt == "char" || dt == "varchar" || dt == "tinytext" || dt == "text" || dt == "mediumtext" || dt == "longtext") }
function is_tinyint1(c,    ct) { ct = tolower(col(c, "column_type")); gsub(/ /, "", ct); return (index(ct, "tinyint(1)") == 1 || index(ct, "bool") == 1) }
function type_max(dt, uns) {
    if (dt == "tinyint") return uns ? "255" : "127"
    if (dt == "smallint") return uns ? "65535" : "32767"
    if (dt == "mediumint") return uns ? "16777215" : "8388607"
    if (dt == "int" || dt == "integer") return uns ? "4294967295" : "2147483647"
    if (dt == "bigint") return uns ? "18446744073709551615" : "9223372036854775807"
    if (dt == "year") return "2155"
    return "1000000"
}
function choose_auto(c,    dt, name, key) {
    dt = tolower(col(c, "data_type")); name = tolower(col(c, "name"))
    if (yes(col(c, "is_generated"))) return "skip"
    if (dt == "geometry" || dt == "point" || dt == "linestring" || dt == "polygon") return "skip"
    if (yes(col(c, "is_auto_increment")) && is_int(dt)) return "unique"
    if (yes(col(c, "is_auto_increment"))) return "skip"
    if (col(c, "fk_table") != "" && col(c, "fk_column") != "") {
        if (col(c, "reference_table") == "") setcol(c, "reference_table", col(c, "fk_table"))
        if (col(c, "reference_column") == "") setcol(c, "reference_column", col(c, "fk_column"))
        return "reference"
    }
    key = (toupper(col(c, "column_key")) == "PRI" || toupper(col(c, "column_key")) == "UNI")
    if (key && is_int(dt)) return "unique"
    if (key && is_string(dt)) { if (col(c, "unique_mode") == "") setcol(c, "unique_mode", "sequence_prefixed"); return "unique" }
    if (dt == "enum" || dt == "set") return "choice"
    if (is_tinyint1(c)) return "choice"
    if (is_int(dt) || dt == "bit" || dt == "year") return "range"
    if (is_decimal(dt)) return "range"
    if (dt == "date" || dt == "datetime" || dt == "timestamp" || dt == "time") return "datetime"
    if (dt == "json") return "template"
    if (is_string(dt)) {
        if (index(name, "uuid") || index(name, "guid")) return "unique"
        if (index(name, "email")) return "template"
        if (index(name, "phone") || index(name, "tel") || index(name, "zip") || index(name, "postal")) return "pattern"
        return "random"
    }
    return "skip"
}
function fill_column(c,    dt, name, mode, uns, cap, scale, tmax, want, len) {
    dt = tolower(col(c, "data_type")); name = tolower(col(c, "name"))
    if (col(c, "strategy") == "unique") {
        mode = tolower(col(c, "unique_mode"))
        if (mode == "") {
            if (index(name, "uuid") || index(name, "guid")) mode = "uuid"
            else if (is_int(dt) || dt == "year" || dt == "bit") mode = "sequence"
            else mode = "sequence_prefixed"
            setcol(c, "unique_mode", mode)
        }
        if (mode == "sequence_prefixed") {
            if (col(c, "unique_prefix") == "") {
                cap = col(c, "name"); if (length(cap) > 3) cap = substr(cap, 1, 3)
                setcol(c, "unique_prefix", toupper(cap) "_")
            }
            if (col(c, "unique_pad") == "") setcol(c, "unique_pad", "8")
        }
    } else if (col(c, "strategy") == "choice") {
        if (col(c, "choice_list") == "" && col(c, "enum_values") != "") setcol(c, "choice_list", col(c, "enum_values"))
        if (col(c, "choice_list") == "" && is_tinyint1(c)) setcol(c, "choice_list", "0|1")
    } else if (col(c, "strategy") == "range") {
        uns = yes(col(c, "is_unsigned")) || index(tolower(col(c, "column_type")), "unsigned")
        if (dt == "year") {
            if (col(c, "range_min") == "") setcol(c, "range_min", "2020")
            if (col(c, "range_max") == "") setcol(c, "range_max", "2026")
        } else if (is_int(dt) || dt == "bit") {
            if (col(c, "range_min") == "") setcol(c, "range_min", "0")
            if (col(c, "range_max") == "") {
                tmax = type_max(dt, uns)
                cap = dec_cmp(tmax, "1000000") > 0 ? "1000000" : tmax
                setcol(c, "range_max", cap)
            }
        } else if (is_decimal(dt)) {
            scale = col(c, "num_scale"); if (scale == "") scale = (dt == "float" || dt == "double" || dt == "real") ? 4 : 0
            if (col(c, "range_min") == "") setcol(c, "range_min", format_units("0", scale))
            if (col(c, "range_max") == "") {
                want = to_units("100000", scale)
                tmax = col(c, "num_precision"); if (tmax == "") tmax = 10
                if ((tmax + 0) < (scale + 0)) tmax = scale
                cap = ""
                for (len = 0; len < (tmax + 0); len++) cap = cap "9"
                if (cap == "") cap = "9"
                if (dec_cmp(want, cap) > 0) want = cap
                setcol(c, "range_max", format_units(want, scale))
            }
        }
    } else if (col(c, "strategy") == "datetime") {
        if (dt == "time") {
            if (col(c, "range_min") == "") setcol(c, "range_min", "00:00:00")
            if (col(c, "range_max") == "") setcol(c, "range_max", "23:59:59")
        } else if (dt == "date") {
            if (col(c, "range_min") == "") setcol(c, "range_min", "2024-01-01")
            if (col(c, "range_max") == "") setcol(c, "range_max", "2026-12-31")
        } else {
            if (col(c, "range_min") == "") setcol(c, "range_min", "2024-01-01 00:00:00")
            if (col(c, "range_max") == "") setcol(c, "range_max", "2026-12-31 23:59:59")
        }
    } else if (col(c, "strategy") == "template" && col(c, "template") == "") {
        if (dt == "json") setcol(c, "template", "{\"n\":{seq}}")
        else if (index(name, "email")) {
            len = col(c, "char_length"); if (len == "") len = 255
            setcol(c, "template", (len + 0) >= 18 ? "user{seq}@example.test" : "u{seq}@e.test")
        }
    } else if (col(c, "strategy") == "pattern" && col(c, "pattern") == "") {
        len = col(c, "char_length"); if (len == "") len = 32
        if (index(name, "phone") || index(name, "tel")) setcol(c, "pattern", (len + 0) >= 13 ? "090-####-####" : "##########")
        else if (index(name, "zip") || index(name, "postal")) setcol(c, "pattern", (len + 0) >= 8 ? "###-####" : "########")
    } else if (col(c, "strategy") == "random" && col(c, "string_length") == "") {
        len = col(c, "char_length") + 0
        if (len <= 0 || len > 64 || dt == "text") len = 16
        else if (len > 12) len = 12
        if (len < 1) len = 1
        setcol(c, "string_length", sprintf("%d", len))
    } else if (col(c, "strategy") == "reference") {
        if (col(c, "reference_table") == "") setcol(c, "reference_table", col(c, "fk_table"))
        if (col(c, "reference_column") == "") setcol(c, "reference_column", col(c, "fk_column"))
        if (col(c, "reference_step") == "") setcol(c, "reference_step", "1")
    }
}
function resolve_column(c,    strategy) {
    if (col(c, "unique_step") == "") setcol(c, "unique_step", "1")
    strategy = tolower(trim(col(c, "strategy")))
    if (strategy == "" || strategy == "auto") strategy = choose_auto(c)
    setcol(c, "strategy", strategy)
    fill_column(c)
}
function cell_value(c, row, seed, table,    strategy, dt, scale, a, b, span, pick, items, m, mode, len, value, isnull) {
    strategy = col(c, "strategy"); dt = tolower(col(c, "data_type")); isnull = 0; value = ""
    if (strategy == "null") return "\001"
    if (strategy == "const") {
        if (col(c, "const_value") == "$NULL$") return "\001"
        value = col(c, "const_value")
    } else if (strategy == "unique") {
        mode = tolower(col(c, "unique_mode"))
        if (mode == "uuid") value = make_uuid(seed, table, col(c, "name"), row)
        else if (mode == "sequence_prefixed") value = col(c, "unique_prefix") seq_digits(col(c, "unique_start"), col(c, "unique_step"), row, col(c, "unique_pad") + 0)
        else value = seq_digits(col(c, "unique_start"), col(c, "unique_step"), row, 0)
    } else if (strategy == "range") {
        scale = 0
        if (is_decimal(dt)) { scale = col(c, "num_scale"); if (scale == "") scale = (dt == "float" || dt == "double" || dt == "real") ? 4 : 0 }
        a = to_units(col(c, "range_min"), scale)
        b = to_units(col(c, "range_max"), scale)
        span = dec_add(dec_sub(b, a), "1")
        pick = dec_add(a, rng_bounded_dec(span))
        value = (scale + 0) == 0 ? pick : format_units(pick, scale)
    } else if (strategy == "datetime") {
        value = date_value(col(c, "range_min"), col(c, "range_max"), dt, col(c, "datetime_precision"))
    } else if (strategy == "choice") {
        m = split_pipes(col(c, "choice_list"), items)
        value = items[draw_index(m) + 1]
        if (value == "$NULL$") return "\001"
    } else if (strategy == "random") {
        len = col(c, "string_length") + 0
        value = ""
        for (m = 0; m < len; m++) value = value substr(ALNUM, draw_index(62) + 1, 1)
    } else if (strategy == "template") {
        value = eval_template(col(c, "template"), col(c, "unique_start"), col(c, "unique_step"), row, seed, table, col(c, "name"))
    } else if (strategy == "pattern") {
        value = eval_pattern(col(c, "pattern"))
    } else if (strategy == "reference") {
        mode = tolower(col(c, "reference_mode"))
        if (mode == "" && col(c, "reference_start") != "" && col(c, "reference_count") != "") mode = "virtual"
        if (mode != "virtual") fail("bash generate supports reference_mode=virtual; use PowerShell for a live reference pool")
        pick = rng_bounded_dec(col(c, "reference_count"))
        value = dec_add(col(c, "reference_start") == "" ? "1" : col(c, "reference_start"), dec_mul(pick, col(c, "reference_step") == "" ? "1" : col(c, "reference_step")))
    } else fail("cannot generate strategy " strategy " on " table "." col(c, "name"))
    return value
}
function dec_sub(a, b,    i, borrow, da, db, t, s) {
    a = dec_norm(a); b = dec_norm(b)
    if (dec_cmp(a, b) < 0) fail("negative decimal result")
    borrow = 0; s = ""; i = 0
    while (i < length(a)) {
        da = substr(a, length(a) - i, 1) + 0
        db = (i < length(b)) ? substr(b, length(b) - i, 1) + 0 : 0
        t = da - db - borrow
        if (t < 0) { t += 10; borrow = 1 } else borrow = 0
        s = t s
        i++
    }
    return dec_norm(s)
}
function unquote(v,    inner) {
    if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") {
        inner = substr(v, 2, length(v) - 2)
        gsub(/\\"/, "\001", inner)
        gsub(/\\\\/, "\\", inner)
        gsub(/\001/, "\"", inner)
        return inner
    }
    return trim(v)
}
function job_or(k, fallback) { return (k in JOB && JOB[k] != "") ? JOB[k] : fallback }
function sort_cols(nout, names, cols,    i, j, keyc, keyn, keyo, ordv) {
    for (i = 1; i <= nout; i++) ordv[i] = col(cols[i], "ordinal") + 0
    for (i = 2; i <= nout; i++) {
        keyc = cols[i]; keyn = names[i]; keyo = ordv[i]; j = i - 1
        while (j >= 1 && ordv[j] > keyo) {
            cols[j + 1] = cols[j]; names[j + 1] = names[j]; ordv[j + 1] = ordv[j]; j--
        }
        cols[j + 1] = keyc; names[j + 1] = keyn; ordv[j + 1] = keyo
    }
}
function generate_csv(    t, c, nout, names, cols, rowcount, seed, line, i, row, value, table) {
    seed = job_or("seed", "1")
    for (t = 1; t <= NT; t++) {
        if (toupper(TINC[t]) == "NO") continue
        if (only != "" && TNAME[t] != only) continue
        nout = 0
        for (c = 1; c <= NC; c++) {
            if (COL[c, "table"] != TNAME[t]) continue
            resolve_column(c)
            if (toupper(col(c, "include")) == "NO") continue
            if (col(c, "strategy") == "skip" || col(c, "strategy") == "expression") continue
            nout++; names[nout] = col(c, "name"); cols[nout] = c
        }
        sort_cols(nout, names, cols)
        rowcount = TROW[t] != "" ? TROW[t] : job_or("row_count", "1000")
        rng_init(fnv_mix(seed, TNAME[t]))
        line = ""
        for (i = 1; i <= nout; i++) line = line (i > 1 ? "," : "") csv_field(names[i], 0)
        print line
        for (row = 0; row < (rowcount + 0); row++) {
            line = ""
            for (i = 1; i <= nout; i++) {
                value = cell_value(cols[i], sprintf("%d", row), seed, TNAME[t])
                line = line (i > 1 ? "," : "") csv_field(value == "\001" ? "" : value, value == "\001")
            }
            print line
        }
    }
}
function dump_args(    i, scope) {
    print "--defaults-extra-file=" defaults
    print "--single-transaction"
    print "--quick"
    print "--skip-lock-tables"
    print "--no-tablespaces"
    print "--set-gtid-purged=OFF"
    print "--column-statistics=0"
    print "--default-character-set=utf8mb4"
    print "--hex-blob"
    if (toupper(job_or("dump_routines", "YES")) == "YES") print "--routines"
    if (toupper(job_or("dump_triggers", "YES")) == "YES") print "--triggers"
    if (toupper(job_or("dump_events", "YES")) == "YES") print "--events"
    scope = job_or("dump_scope", "database")
    if (scope == "tables") {
        print CONN["database"]
        for (i = 1; i <= NT; i++) if (toupper(TINC[i]) != "NO") print TNAME[i]
    } else {
        print "--databases"
        print CONN["database"]
    }
    print "--result-file=" result
}
function selftest() {
    if (u_mul("000000000000ffff", "000000000000ffff") != "00000000fffe0001") fail("mul")
    if (u_add("ffffffffffffffff", "0000000000000001") != "0000000000000000") fail("add")
    if (u_shr("0000000000000010", 4) != "0000000000000001") fail("shr")
    if (u_shl("0000000000000001", 4) != "0000000000000010") fail("shl")
    if (u_shl("0000000000000001", 25) != "0000000002000000") fail("shl25")
    if (u_from_dec("65535") != "000000000000ffff") fail("fromdec")
    if (u_to_dec("000000000000ffff") != "65535") fail("todec")
    if (u_divmod("0000000000000064", "000000000000000a") != "000000000000000a") fail("div")
    if (U_MOD != "0000000000000000") fail("mod")
    print "selftest ok"
}
function rng_demo(    i, mixed) {
    mixed = fnv_mix(seed == "" ? "1" : seed, text == "" ? "demo" : text)
    rng_init(mixed)
    print mixed
    for (i = 0; i < 5; i++) print rng_next()
}
function ticks_demo() {
    print format_when(parse_when_ticks("2024-01-01 00:00:00", "datetime"), "datetime")
    print u_to_dec(parse_when_ticks("2024-01-01 00:00:00", "datetime"))
}
BEGIN {
    DIGITS = "0123456789"
    UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    LOWER = "abcdefghijklmnopqrstuvwxyz"
    ALNUM = UPPER LOWER DIGITS
    HEXL = "0123456789abcdef"
    init_ord()
    NT = 0; NC = 0; section = ""
    if (mode == "selftest") { selftest(); exit 0 }
    if (mode == "rng") { rng_demo(); exit 0 }
    if (mode == "ticks") { ticks_demo(); exit 0 }
}
{
    line = $0
    sub(/\r$/, "", line)
    trimmed = line
    sub(/^[ \t]+/, "", trimmed)
    if (trimmed == "" || substr(trimmed, 1, 1) == "#") next
    if (substr(trimmed, 1, 1) == "[" && substr(trimmed, length(trimmed), 1) == "]") {
        section = tolower(substr(trimmed, 2, length(trimmed) - 2))
        gsub(/^[ \t]+|[ \t]+$/, "", section)
        if (section == "table") { NT++; TINC[NT] = "YES"; TROW[NT] = "" }
        if (section == "column") NC++
        next
    }
    eq = index(line, "=")
    if (eq < 2) fail("expected key=value")
    key = tolower(trim(substr(line, 1, eq - 1)))
    value = unquote(substr(line, eq + 1))
    if (key == "password") fail("do not store a password in the plan")
    if (section == "job") JOB[key] = value
    else if (section == "connection") CONN[key] = value
    else if (section == "meta") META[key] = value
    else if (section == "table") {
        if (key == "name") TNAME[NT] = value
        else if (key == "include") TINC[NT] = value
        else if (key == "row_count") TROW[NT] = value
    } else if (section == "column") COL[NC, key] = value
}
END {
    if (mode == "dumpargs") dump_args()
    else if (mode == "tables") {
        for (t = 1; t <= NT; t++) if (toupper(TINC[t]) != "NO") print TNAME[t]
    }
    else if (mode == "csv" || mode == "") generate_csv()
}
