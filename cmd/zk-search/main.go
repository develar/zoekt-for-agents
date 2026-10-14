// zk-search: a thin Zoekt query client with result caps, used by the zk wrapper.
// Output is grep-like (`path:line:text`), or file names with -l.
package main

import (
	"bufio"
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/sourcegraph/zoekt"
	"github.com/sourcegraph/zoekt/query"
	"github.com/sourcegraph/zoekt/search"
)

func main() {
	indexDir := flag.String("index_dir", filepath.Join(os.Getenv("HOME"), ".zoekt", "index"), "index directory")
	list := flag.Bool("l", false, "print matching file names only")
	maxMatches := flag.Int("max_matches", 2000, "stop searching after this many matches in total (0 = unlimited)")
	maxFiles := flag.Int("max_files", 500, "show at most this many files (0 = unlimited)")
	maxLines := flag.Int("max_lines", 20, "show at most this many matching lines per file (0 = unlimited)")
	maxWall := flag.Duration("max_wall", 20*time.Second, "abort the search after this long")
	context := flag.Int("context", 0, "context lines around each match")
	verbose := flag.Bool("v", false, "print query and stats to stderr")
	flag.Parse()
	if flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: zk-search [flags] QUERY")
		flag.PrintDefaults()
		os.Exit(2)
	}
	pat := strings.Join(flag.Args(), " ")
	if !*verbose {
		log.SetOutput(io.Discard) // zoekt logs shard loading at INFO level
	}

	searcher, err := search.NewDirectorySearcher(*indexDir)
	if err != nil {
		log.Fatal(err)
	}
	q, err := query.Parse(pat)
	if err != nil {
		log.Fatal(err)
	}
	q = query.Simplify(query.Map(q, query.ExpandFileContent))
	if *verbose {
		fmt.Fprintln(os.Stderr, "query:", q)
	}
	opts := zoekt.SearchOptions{
		ShardMaxMatchCount: *maxMatches,
		TotalMaxMatchCount: *maxMatches,
		MaxDocDisplayCount: *maxFiles,
		MaxWallTime:        *maxWall,
		NumContextLines:    *context,
	}
	res, err := searcher.Search(ctx(), q, &opts)
	if err != nil {
		log.Fatal(err)
	}
	out := bufferedStdout()
	defer out.Flush()
	for _, f := range res.Files {
		if *list {
			fmt.Fprintln(out, f.FileName)
			continue
		}
		for i, m := range f.LineMatches {
			if *maxLines > 0 && i >= *maxLines {
				fmt.Fprintf(out, "%s: ... %d more matching lines in this file\n", f.FileName, len(f.LineMatches)-i)
				break
			}
			if m.FileName {
				continue
			}
			printContext(out, f.FileName, m.Before, m.LineNumber-1, true)
			fmt.Fprintf(out, "%s:%d:%s\n", f.FileName, m.LineNumber, bytes.TrimSuffix(m.Line, []byte{'\n'}))
			printContext(out, f.FileName, m.After, m.LineNumber+1, false)
		}
	}
	if res.Stats.FilesSkipped > 0 || res.Stats.ShardsSkipped > 0 || (*maxFiles > 0 && res.Stats.FileCount > *maxFiles) {
		fmt.Fprintf(os.Stderr, "zk-search: results truncated (%d files matched, %d shown); narrow the query with f: lang: -f: or raise -max_files\n",
			res.Stats.FileCount, len(res.Files))
	}
	if *verbose {
		fmt.Fprintf(os.Stderr, "stats: files=%d matches=%d shards_skipped=%d files_skipped=%d wall=%s\n",
			res.Stats.FileCount, res.Stats.MatchCount, res.Stats.ShardsSkipped, res.Stats.FilesSkipped, res.Stats.Duration)
	}
}

func ctx() context.Context { return context.Background() }

// printContext prints a block of context lines; `last` is the line number of the last line for a
// block preceding the match, or of the first line for a block following it.
func printContext(out *bufio.Writer, name string, block []byte, at int, before bool) {
	block = bytes.TrimSuffix(block, []byte{'\n'})
	if len(block) == 0 {
		return
	}
	lines := bytes.Split(block, []byte{'\n'})
	for i, l := range lines {
		n := at + i
		if before {
			n = at - len(lines) + 1 + i
		}
		fmt.Fprintf(out, "%s-%d-%s\n", name, n, l)
	}
}
