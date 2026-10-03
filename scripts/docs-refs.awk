# docs-refs.awk — engine for scripts/docs-refs.sh. See that file for usage.
#
# Inputs via -v:
#   mode     "check" (verify, exit 1 on drift) or "sync" (renumber and rewrite)
#   lock     path to the lock file, or "" when it does not exist yet
#   havelock "1" when the lock file exists
#   paths    scratch file of "Base.swift<FSSEP>source/path" (resolved by the wrapper)
#   tmp      scratch directory (sync writes rewritten markdown and the new lock there)
# ARGV: the docs/forges/*.md files.
#
# The lock anchors each cited line number to the trimmed content of the line it
# cited (fields separated by \034): <markdown file> <Base.swift> <line> <content>.
# A range anchors its endpoints only — interior lines (blanks, braces) are
# descriptive, and anchoring each of them makes nearest-match ties fragment the
# range. check fails when a cited line no longer holds its anchored content;
# sync re-finds each anchored line in the source (nearest match to the old
# number), renumbers the citation, and rewrites both the markdown and the lock.

function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t\r]+$/, "", s); return s }

# Parse "17,164-193" into parts[1..n] (each "N" or "A-B"); returns n.
function parseSpec(spec, parts) { return split(spec, parts, ",") }

# Expand one part into nums[1..k] with anchored[i] flags (endpoints only for
# ranges; every line for a single number).
function partLines(part, nums, anchored,   k, ab, a, b, j, t) {
    k = 0
    if (part ~ /^[0-9]+-[0-9]+$/) {
        split(part, ab, "-")
        a = ab[1] + 0; b = ab[2] + 0
        if (a > b) { t = a; a = b; b = t }
        nums[++k] = a; anchored[k] = 1
        for (j = a + 1; j <= b - 1; j++) { nums[++k] = j; anchored[k] = 0 }
        if (b > a) { nums[++k] = b; anchored[k] = 1 }
    } else if (part ~ /^[0-9]+$/) {
        nums[++k] = part + 0; anchored[k] = 1
    }
    return k
}

# Canonical "1,2,5-9" form: sorted, runs of consecutive numbers collapsed.
function canonical(nums, k,   i, j, v, s, runstart, prev) {
    for (i = 2; i <= k; i++) {
        v = nums[i]
        for (j = i - 1; j >= 1 && nums[j] > v; j--) nums[j + 1] = nums[j]
        nums[j + 1] = v
    }
    s = ""
    runstart = nums[1]; prev = nums[1]
    for (i = 2; i <= k; i++) {
        if (nums[i] == prev + 1) { prev = nums[i]; continue }
        s = s ((runstart == prev) ? runstart : runstart "-" prev) ","
        runstart = nums[i]; prev = nums[i]
    }
    return s ((runstart == prev) ? runstart : runstart "-" prev)
}

# Replace every occurrence of `old` in `line` with `new` (plain text).
function splice(line, old, new,   out, pos, idx) {
    out = ""; pos = 1
    while ((idx = index(substr(line, pos), old)) > 0) {
        idx += pos - 1
        out = out substr(line, pos, idx - pos) new
        pos = idx + length(old)
    }
    return out substr(line, pos)
}

function basenameOf(token,   s) { s = token; sub(/:.*/, "", s); return s }
function specOf(token,   s) { s = token; sub(/^[^:]*:/, "", s); sub(/~/, "", s); gsub(/[^0-9,-]/, "", s); return s }

BEGIN {
    FSSEP = "\034"
    bad = 0; totalCitations = 0
    if (havelock == "1") {
        while ((getline line < lock) > 0) {
            if (line == "" || line ~ /^#/) continue
            n = split(line, f, FSSEP)
            if (n < 4) { printf "docs-refs: malformed lock line: %s\n", line > "/dev/stderr"; bad = 1; continue }
            k = f[1] FSSEP f[2] FSSEP f[3]
            lockContent[k] = f[4]
            lockKeys[++lockKeyCount] = k
        }
        close(lock)
    }
    while ((getline line < paths) > 0) {
        if (line == "") continue
        n = split(line, f, FSSEP)
        swiftPath[f[1]] = f[2]
    }
    close(paths)
    for (base in swiftPath) {
        p = swiftPath[base]; c = 0
        while ((getline l < p) > 0) { c++; swiftLine[p, c] = trim(l) }
        close(p)
        swiftCount[p] = c
    }
}

FILENAME ~ /\.md$/ {
    md = FILENAME
    mdsSeen[md] = 1
    if (mode == "sync") mdLines[md, FNR] = $0
    if (FNR > mdCount[md]) mdCount[md] = FNR
    rest = $0
    while (match(rest, /[A-Za-z0-9+]+\.swift:~?[0-9][0-9,-]*/)) {
        token = substr(rest, RSTART, RLENGTH)
        key = md FSSEP token
        if (!(key in tokenSpec)) { tokenSpec[key] = specOf(token); tokenOrder[++tokenKeyCount] = key }
        base = basenameOf(token)
        if (mode == "check") {
            nparts = parseSpec(tokenSpec[key], parts)
            for (pi = 1; pi <= nparts; pi++) {
                kk = partLines(parts[pi], nums, anchoredFlags)
                for (i = 1; i <= kk; i++) {
                    if (!anchoredFlags[i]) continue
                    nnum = nums[i]; totalCitations++
                    lk = md FSSEP base FSSEP nnum
                    seenLock[lk] = 1
                    p = swiftPath[base]
                    if (!(lk in lockContent)) {
                        printf "::error file=%s,line=%d::unlocked docs reference — %s (run scripts/docs-refs.sh sync)\n", md, FNR, token
                        bad = 1
                    } else if (nnum > swiftCount[p]) {
                        printf "::error file=%s,line=%d::stale docs reference — %s: line %d is past the end of %s\n", md, FNR, token, nnum, p
                        bad = 1
                    } else if (swiftLine[p, nnum] != lockContent[lk]) {
                        printf "::error file=%s,line=%d::stale docs reference — %s no longer points at the code it cites (run scripts/docs-refs.sh sync)\n", md, FNR, token
                        bad = 1
                    }
                }
            }
        }
        rest = substr(rest, RSTART + RLENGTH)
    }
}

END {
    if (mode == "sync") {
        moved = 0; ambiguous = 0; unfixable = 0
        for (ki = 1; ki <= tokenKeyCount; ki++) {
            key = tokenOrder[ki]
            split(key, kp, FSSEP)
            md = kp[1]; token = kp[2]
            base = basenameOf(token)
            p = swiftPath[base]
            nparts = parseSpec(tokenSpec[key], parts)
            newSpec = ""
            for (pi = 1; pi <= nparts; pi++) {
                kk = partLines(parts[pi], nums, anchoredFlags)
                pm = split("", pnums)
                for (i = 1; i <= kk; i++) {
                    if (!anchoredFlags[i]) continue
                    nnum = nums[i]
                    lk = md FSSEP base FSSEP nnum
                    if (lk in lockContent) content = lockContent[lk]
                    else if (nnum <= swiftCount[p]) content = swiftLine[p, nnum]
                    else {
                        printf "docs-refs: %s: %s — line %d is out of range; fix it by hand\n", md, token, nnum > "/dev/stderr"
                        unfixable++
                        pnums[++pm] = nnum
                        newLock[md FSSEP base FSSEP nnum] = (lk in lockContent) ? lockContent[lk] : ""
                        continue
                    }
                    bestd = -1; bestn = nnum; ties = 0
                    for (c = 1; c <= swiftCount[p]; c++) {
                        if (swiftLine[p, c] == content) {
                            d = (c >= nnum) ? c - nnum : nnum - c
                            if (bestd < 0 || d < bestd) { bestd = d; bestn = c; ties = 0 }
                            else if (d == bestd) ties++
                        }
                    }
                    if (bestd < 0) {
                        printf "docs-refs: %s: %s — the cited line's content was not found in %s; left as-is\n", md, token, p > "/dev/stderr"
                        unfixable++
                        newn = nnum
                    } else {
                        newn = bestn
                        if (ties > 0) ambiguous++
                        if (newn != nnum) moved++
                    }
                    pnums[++pm] = newn
                    nk = md FSSEP base FSSEP newn
                    if ((nk in newLock) && newLock[nk] != content)
                        printf "docs-refs: %s:%d is cited with two different contents\n", base, newn > "/dev/stderr"
                    newLock[nk] = content
                }
                if (pm == 0) continue
                partText = canonical(pnums, pm)
                newSpec = (newSpec == "") ? partText : newSpec "," partText
            }
            if (newSpec == "") continue
            totalCitations += nparts
            newToken = base ":" newSpec
            if (newToken != token) { dirty[md] = 1; tokenNew[key] = newToken }
        }
        written = 0
        for (ki = 1; ki <= tokenKeyCount; ki++) {
            key = tokenOrder[ki]
            split(key, kp, FSSEP)
            md = kp[1]
            if (!(md in dirty) || (md in mdWritten)) continue
            mdWritten[md] = 1
            out = tmp "/rewritten." (++written)
            for (i = 1; i <= mdCount[md]; i++) {
                line = mdLines[md, i]
                for (kj = 1; kj <= tokenKeyCount; kj++) {
                    k2 = tokenOrder[kj]
                    split(k2, kp2, FSSEP)
                    if (kp2[1] != md || !(k2 in tokenNew)) continue
                    line = splice(line, kp2[2], tokenNew[k2])
                }
                print line > (out)
            }
            close(out)
            printf "%s\t%s\n", md, out > (tmp "/rewritten.map")
        }
        cmd = "sort > '" tmp "/lock.new'"
        for (k in newLock) print k FSSEP newLock[k] | cmd
        close(cmd)
        printf "docs-refs: %d citation(s), %d renumbered, %d ambiguous, %d need a hand\n", totalCitations, moved, ambiguous, unfixable
        exit unfixable > 0 ? 1 : 0
    } else {
        if (!havelock && totalCitations > 0) {
            print "docs-refs: no lock (scripts/docs-refs.lock) — run scripts/docs-refs.sh sync to seed it" > "/dev/stderr"
            exit 1
        }
        stale = 0
        for (ki = 1; ki <= lockKeyCount; ki++) {
            k = lockKeys[ki]
            if (!(k in seenLock)) {
                split(k, f, FSSEP)
                printf "::error file=%s::stale lock entry — %s:%s is no longer cited (run scripts/docs-refs.sh sync)\n", f[1], f[2], f[3]
                stale++
            }
        }
        if (bad == 0 && stale == 0) {
            fileCount = 0
            for (md in mdsSeen) fileCount++
            printf "docs-refs: clean (%d cited line(s) in %d file(s))\n", totalCitations, fileCount
        }
        exit (bad || stale) ? 1 : 0
    }
}
