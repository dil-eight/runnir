#!/bin/sh
# Pain tracker: public threads where people describe problems Runnir addresses.
#
#   scripts/pain-tracker.sh refresh                              update comment counts and states of recorded threads
#   scripts/pain-tracker.sh collect                              candidate threads not yet recorded or rejected
#   scripts/pain-tracker.sh add PAIN DATE PLATFORM URL COMMENTS STATUS "what they ask"
#   scripts/pain-tracker.sh reject URL...                        remember threads that do not fit
#   scripts/pain-tracker.sh render                               rebuild docs/research/pain-tracker.md
#
# Data: docs/research/pains.tsv (definitions), pain-sources.tsv (threads), pain-rejected.txt.
# Needs gh (signed in; reads public data only), curl, jq and awk. TRACKER_TODAY=YYYY-MM-DD overrides the date.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="$ROOT/docs/research"
DEFS="$DIR/pains.tsv"
SRC="$DIR/pain-sources.tsv"
REJ="$DIR/pain-rejected.txt"
OUT="$DIR/pain-tracker.md"
TAB=$(printf '\t')
TODAY=${TRACKER_TODAY:-$(date +%Y-%m-%d)}
WINDOW_DAYS=183

touch "$SRC" "$REJ"

# shift_days DATE DAYS: DATE moved by DAYS (negative = earlier), BSD or GNU date.
shift_days() {
	if date -j -v"${2}d" -f %Y-%m-%d "$1" +%Y-%m-%d 2>/dev/null; then
		return
	fi
	date -d "$1 $2 days" +%Y-%m-%d
}

epoch() {
	date -j -f %Y-%m-%d "$1" +%s 2>/dev/null || date -d "$1" +%s
}

WINDOW_START=$(shift_days "$TODAY" -$WINDOW_DAYS)

# Issue repositories searched next to the GitHub Community discussions.
ISSUE_REPOS="repo:nektos/act repo:actions/runner"

queries_of() {
	printf '%s\n' "$1" | awk -F ' ;; ' '{ for (i = 1; i <= NF; i++) print $i }'
}

# Rows: date, platform, url, comments, status, title
search_discussions() {
	gh api graphql -f query='query($q:String!){search(query:$q,type:DISCUSSION,first:20){nodes{... on Discussion{title url createdAt isAnswered closed comments{totalCount}}}}}' \
		-f q="repo:community/community $1 created:>=$WINDOW_START" \
		--jq '.data.search.nodes[] | [.createdAt[0:10], "github-discussion", .url, .comments.totalCount, (if .isAnswered then "answered" elif .closed then "closed" else "open" end), .title] | @tsv'
}

search_issues() {
	gh api graphql -f query='query($q:String!){search(query:$q,type:ISSUE,first:20){nodes{... on Issue{title url createdAt state comments{totalCount}}}}}' \
		-f q="$ISSUE_REPOS is:issue $1 created:>=$WINDOW_START" \
		--jq '.data.search.nodes[] | [.createdAt[0:10], "github-issue", .url, .comments.totalCount, (if .state == "OPEN" then "open" else "closed" end), .title] | @tsv'
}

search_hn() {
	curl -fsS -G "https://hn.algolia.com/api/v1/search_by_date" \
		--data-urlencode "query=github actions $1" --data-urlencode "tags=story" \
		--data-urlencode "numericFilters=created_at_i>=$(epoch "$WINDOW_START")" \
		--data-urlencode "hitsPerPage=20" |
		jq -r '.hits[] | [.created_at[0:10], "hacker-news", "https://news.ycombinator.com/item?id=\(.objectID)", (.num_comments // 0), "open", .title] | @tsv'
}

collect() {
	raw=$(mktemp)
	known=$(mktemp)
	cut -f1,4 "$SRC" >"$known"
	grep -v '^#' "$DEFS" | while IFS="$TAB" read -r id _title _state _answer queries; do
		queries_of "$queries" | while IFS= read -r q; do
			for source in search_discussions search_issues search_hn; do
				if found=$("$source" "$q" 2>/dev/null </dev/null); then
					[ -z "$found" ] || printf '%s\n' "$found" | awk -F "$TAB" -v id="$id" '{ print id "\t" $0 }' >>"$raw"
				else
					echo "pain-tracker: $source failed for '$q'" >&2
				fi
				sleep 1
			done
		done
	done
	# One line per thread; the pains it matched are joined. Threads recorded for a
	# pain or rejected are left out.
	awk -F "$TAB" -v known="$known" -v rej="$REJ" '
		BEGIN {
			while ((getline line < known) > 0) { split(line, k, "\t"); have[k[1] SUBSEP k[2]] = 1 }
			while ((getline line < rej) > 0) rejected[line] = 1
		}
		{
			url = $4
			if (url in rejected) next
			if (($1 SUBSEP url) in have) next
			if (!(url in row)) { row[url] = $2 "\t" $3 "\t" url "\t" $5 "\t" $6 "\t" $7; order[++n] = url }
			if (index("," pains[url] ",", "," $1 ",") == 0) pains[url] = pains[url] (pains[url] == "" ? "" : ",") $1
		}
		END { for (i = 1; i <= n; i++) print pains[order[i]] "\t" row[order[i]] }
	' "$raw" | sort -t "$TAB" -k2,2r
	rm -f "$raw" "$known"
}

add() {
	if [ $# -ne 7 ]; then
		echo "usage: add PAIN DATE PLATFORM URL COMMENTS STATUS \"what they ask\"" >&2
		exit 2
	fi
	if ! grep -q "^$1$TAB" "$DEFS"; then
		echo "unknown pain $1" >&2
		exit 2
	fi
	if awk -F "$TAB" -v p="$1" -v u="$4" '$1 == p && $4 == u { found = 1 } END { exit !found }' "$SRC"; then
		echo "already recorded: $1 $4" >&2
		return
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$TODAY" "$(printf '%s' "$7" | tr '\t\n' '  ')" >>"$SRC"
}

reject() {
	for url in "$@"; do
		grep -qxF "$url" "$REJ" || echo "$url" >>"$REJ"
	done
}

# Re-reads the comment count and state of every recorded GitHub thread, and the
# comment count of Hacker News stories. A thread that cannot be read keeps its row.
refresh() {
	out=$(mktemp)
	while IFS="$TAB" read -r pain posted platform url comments state found ask; do
		got=""
		case "$url" in
		https://github.com/orgs/community/discussions/*)
			got=$(gh api graphql -f query='query($n:Int!){repository(owner:"community",name:"community"){discussion(number:$n){isAnswered closed comments{totalCount}}}}' \
				-F n="${url##*/}" \
				--jq '.data.repository.discussion | [.comments.totalCount, (if .isAnswered then "answered" elif .closed then "closed" else "open" end)] | @tsv' 2>/dev/null </dev/null) || got=""
			;;
		https://github.com/*/issues/*)
			repo=${url#https://github.com/}
			repo=${repo%/issues/*}
			got=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){state comments{totalCount}}}}' \
				-f o="${repo%%/*}" -f r="${repo##*/}" -F n="${url##*/}" \
				--jq '.data.repository.issue | [.comments.totalCount, (if .state == "OPEN" then "open" else "closed" end)] | @tsv' 2>/dev/null </dev/null) || got=""
			;;
		https://news.ycombinator.com/item\?id=*)
			got=$(curl -fsS "https://hn.algolia.com/api/v1/items/${url##*=}" 2>/dev/null </dev/null |
				jq -r '[([.. | objects | select(.type == "comment")] | length), "open"] | @tsv') || got=""
			;;
		esac
		if [ -n "$got" ]; then
			comments=$(printf '%s' "$got" | cut -f1)
			state=$(printf '%s' "$got" | cut -f2)
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pain" "$posted" "$platform" "$url" "$comments" "$state" "$found" "$ask" >>"$out"
		sleep 1
	done <"$SRC"
	cat "$out" >"$SRC"
	rm -f "$out"
}

render() {
	sorted=$(mktemp)
	sort -t "$TAB" -k2,2r "$SRC" >"$sorted"
	week_ago=$(shift_days "$TODAY" -7)
	{
		cat <<EOF
# Pain Tracker

Generated by \`scripts/pain-tracker.sh render\` from [pains.tsv](pains.tsv) and [pain-sources.tsv](pain-sources.tsv); edit those, not this file. Updated $TODAY. Window: posts from $WINDOW_START to $TODAY (the last six months, rolling).

Each row is a public thread where someone describes a problem Runnir addresses. It is a research log of what people ask for, not a measure of the market: the search covers GitHub Community discussions, issues of \`nektos/act\` and \`actions/runner\`, and Hacker News stories about GitHub Actions. Reddit and Stack Overflow cannot be read by the search tools, so threads from them are added by hand when someone finds one. Methods, limits and the daily procedure are in [the findings](github-actions-pain-points.md#pain-tracker).

**Counting.** A thread counts once per pain it describes (one thread can count for several pains). Several posts about one outage, or one author posting the same report twice, count once. Posts older than the window drop out of the counters. Titles are paraphrased, with no usernames or quotes.

**Replying.** Reply only where the thread asks for exactly what Runnir does and the state below says *built*; say that you work on Runnir; follow the community's rules on self-promotion; never reply for a pain marked *planned* or *not-planned* as if it were available. Runnir has no release yet, so there is nothing to download.

EOF
		printf '## Counters\n\n| ID | Pain | Runnir | Threads | Open | New in 7 days | Last found |\n| --- | --- | --- | ---: | ---: | ---: | --- |\n'
		grep -v '^#' "$DEFS" | while IFS="$TAB" read -r id title state answer _queries; do
			awk -F "$TAB" -v id="$id" -v title="$title" -v state="$state" -v answer="$answer" -v start="$WINDOW_START" -v week="$week_ago" '
				$1 == id && $2 >= start { n++; if ($6 == "open") open++; if ($7 >= week) fresh++; if ($7 > last) last = $7 }
				END { printf "| [%s](#%s) | %s | %s: %s | %d | %d | %d | %s |\n", id, tolower(id), title, state, answer, n, open, fresh, (last == "" ? "none" : last) }
			' "$sorted"
		done
		distinct=$(awk -F "$TAB" -v start="$WINDOW_START" '$2 >= start && !seen[$4]++ { n++ } END { print n + 0 }' "$sorted")
		printf '\nDistinct threads in the window: %s.\n' "$distinct"
		grep -v '^#' "$DEFS" | while IFS="$TAB" read -r id title state answer _queries; do
			printf '\n## %s\n\n%s. Runnir: %s, %s\n\n' "$id" "$title" "$state" "$answer"
			awk -F "$TAB" -v id="$id" -v start="$WINDOW_START" '
				function label(u,   m) {
					if (match(u, /discussions\/[0-9]+/)) return "Discussion #" substr(u, RSTART + 12, RLENGTH - 12)
					if (match(u, /github\.com\/[^\/]+\/[^\/]+\/issues\/[0-9]+/)) { m = substr(u, RSTART + 11, RLENGTH - 11); sub(/\/issues\//, "#", m); return m }
					if (match(u, /item\?id=[0-9]+/)) return "HN " substr(u, RSTART + 8, RLENGTH - 8)
					return u
				}
				$1 == id && $2 >= start {
					if (!n++) print "| Posted | Where | Thread | What they ask | Comments | State | Found |\n| --- | --- | --- | --- | ---: | --- | --- |"
					ask = $8; gsub(/\|/, "/", ask)
					printf "| %s | %s | [%s](%s) | %s | %s | %s | %s |\n", $2, $3, label($4), $4, ask, $5, $6, $7
				}
				END { if (!n) print "No threads in the window yet." }
			' "$sorted"
		done
	} >"$OUT"
	rm -f "$sorted"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
collect) collect ;;
refresh) refresh ;;
add) add "$@" ;;
reject) reject "$@" ;;
render) render ;;
*)
	sed -n '2,12p' "$0" >&2
	exit 2
	;;
esac
