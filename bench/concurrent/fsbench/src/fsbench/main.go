package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type FileSystem struct {
	ident    string
	binary   string
	filename string
	args     []string
}

var fscqArgs = []string{"disk.img", "/tmp/fscq"}
var helloArgs = []string{"/tmp/hellofs"}

var fileSystems = []FileSystem{
	{ident: "fscq",
		binary:   "fscq",
		filename: "/tmp/fscq/small-4k",
		args:     fscqArgs},
	{ident: "cfscq",
		binary:   "cfscq",
		filename: "/tmp/fscq/small-4k",
		args:     fscqArgs},
	{ident: "hfuse",
		binary:   "HelloFS",
		filename: "/tmp/hellofs/hello",
		args:     helloArgs},
	{ident: "cfuse",
		binary:   "c-hellofs",
		filename: "/tmp/hellofs/hello",
		args:     helloArgs},
	{ident: "hello",
		binary:   "hello",
		filename: "/tmp/hellofs/hello",
		args:     helloArgs},
	{ident: "fusexmp",
		binary:   "passthrough",
		filename: "/tmp/hellofs/etc/passwd",
		args:     helloArgs},
	{ident: "native",
		binary:   "true",
		filename: "/etc/passwd",
		args:     []string{}},
}

func parseIdent(s string) (FileSystem, error) {
	for _, fs := range fileSystems {
		if fs.ident == s {
			return fs, nil
		}
	}
	return FileSystem{}, fmt.Errorf("unknown filesystem identifier %s", s)
}

func (fs FileSystem) isFuse() bool {
	return fs.ident != "native"
}

func (fs FileSystem) isHaskell() bool {
	return fs.ident == "fscq" || fs.ident == "cfscq" || fs.ident == "hfuse"
}

type fuseOptions struct {
	nameCache    bool
	attrCache    bool
	negNameCache bool
	kernelCache  bool
}

func timeoutIfTrue(name string, toggle bool) string {
	if !toggle {
		return fmt.Sprintf("%s=0", name)
	}
	return fmt.Sprintf("%s=1", name)
}

func (o fuseOptions) optString() string {
	opts := strings.Join([]string{"auto_unmount",
		timeoutIfTrue("entry_timeout", o.nameCache),
		timeoutIfTrue("negative_timeout", o.negNameCache),
		timeoutIfTrue("attr_timeout", o.attrCache),
	}, ",")
	if o.kernelCache {
		opts += ",kernel_cache"
	}
	return opts
}

func (fs FileSystem) Launch(opts fuseOptions) {
	var args []string
	args = append(args, fs.args...)
	if fs.isFuse() {
		args = append(args, "-o", opts.optString())
	}
	if fs.isHaskell() {
		args = append(args, "+RTS", "-N2", "-RTS")
	}
	cmd := exec.Command(fs.binary, args...)
	cmd.Stderr = os.Stderr
	cmd.Run()
}

func (fs FileSystem) Stop() {
	if fs.isFuse() {
		dir := path.Dir(fs.filename)
		if fs.ident == "fusexmp" {
			dir = "/tmp/hellofs"
		}
		cmd := exec.Command("fusermount", "-u", dir)
		err := cmd.Run()
		if err != nil {
			log.Fatal(fmt.Errorf("could not unmount: %v", err))
		}
	}
}

type workloadOptions struct {
	operation    string
	existingPath bool
	kiters       int
}

func (fs FileSystem) RunWorkload(opts workloadOptions, parallel bool) time.Duration {
	path := fs.filename
	if !opts.existingPath {
		path += "x"
	}
	copies := 1
	if parallel {
		copies = 2
	}

	args := []string{opts.operation, path, strconv.Itoa(opts.kiters)}

	start := time.Now()
	done := make(chan bool)
	for i := 0; i < copies; i++ {
		go func() {
			cmd := exec.Command("fsops", args...)
			err := cmd.Run()
			if err != nil {
				log.Fatal(fmt.Errorf("could not run fsops: %v", err))
			}
			done <- true
		}()
	}
	for i := 0; i < copies; i++ {
		<-done
	}
	return time.Now().Sub(start)
}

func printTsv(args ...interface{}) {
	for i, arg := range args {
		fmt.Print(arg)
		if i != len(args)-1 {
			fmt.Print("\t")
		}
	}
	fmt.Print("\n")
}

func toSec(d time.Duration) float64 {
	return float64(d) / float64(time.Second)
}

type DataPoint struct {
	fsIdent string
	fuseOptions
	workloadOptions
	parallel       bool
	elapsedTimeSec float64
	seqTimeSec     float64
}

func (p DataPoint) ParallelSpeedup() float64 {
	return 2 * p.seqTimeSec / p.elapsedTimeSec
}

func (p DataPoint) MicrosPerOp() float64 {
	return p.elapsedTimeSec / float64(p.kiters) * 1000
}

func (p DataPoint) SeqPoint() DataPoint {
	return DataPoint{
		p.fsIdent,
		p.fuseOptions,
		p.workloadOptions,
		false,
		p.seqTimeSec,
		p.seqTimeSec,
	}
}

var DataRowHeader = []interface{}{
	"fs", "name_cache", "attr_cache", "neg_name_cache", "kernel_cache",
	"operation", "exists", "kiters",
	"parallel",
	"timeSec", "seqTimeSec", "speedup", "usPerOp",
}

func (p DataPoint) DataRow() []interface{} {
	return []interface{}{
		p.fsIdent, p.nameCache, p.attrCache, p.negNameCache, p.kernelCache,
		p.operation, p.existingPath, p.kiters,
		p.parallel,
		p.elapsedTimeSec, p.seqTimeSec, p.ParallelSpeedup(), p.MicrosPerOp(),
	}
}

func main() {
	print_header := flag.Bool("print-header", false, "just print a data header")
	operation := flag.String("op", "stat", "operation to perform (stat or open)")
	existingPath := flag.Bool("exists", false, "operate on an existing file")
	parallel := flag.Bool("parallel", false, "run operation in parallel")
	kiters := flag.Int("kiters", 1, "thousands of iterations to run the operation")
	attr_cache := flag.Bool("attr-cache", false, "enable fuse attribute cache")
	name_cache := flag.Bool("name-cache", false, "enable fuse entry (name) cache")
	neg_name_cache := flag.Bool("neg-cache", false, "enable fuse negative (deleted) name cache")
	kernel_cache := flag.Bool("kernel-cache", false, "enable kernel cache")

	flag.Parse()

	if *print_header {
		printTsv(DataRowHeader...)
		return
	}

	if flag.NArg() == 0 {
		log.Fatal(fmt.Errorf("missing file system choice"))
	}

	fsident := flag.Arg(0)
	fs, err := parseIdent(fsident)
	if err != nil {
		log.Fatal(err)
	}
	if !(*operation == "stat" || *operation == "open") {
		log.Fatal(fmt.Errorf("invalid operation %s: expected stat or open", *operation))
	}

	if *parallel {
		runtime.GOMAXPROCS(2)
	}

	fuseOpts := fuseOptions{
		nameCache:    *name_cache,
		negNameCache: *neg_name_cache,
		attrCache:    *attr_cache,
		kernelCache:  *kernel_cache,
	}

	fs.Launch(fuseOpts)

	opts := workloadOptions{
		operation:    *operation,
		existingPath: *existingPath,
		kiters:       *kiters,
	}

	// warmup
	fs.RunWorkload(workloadOptions{
		operation:    *operation,
		existingPath: *existingPath,
		kiters:       1,
	}, false)

	elapsedSec := toSec(fs.RunWorkload(opts, *parallel))
	var seqSec float64
	if *parallel {
		seqSec = toSec(fs.RunWorkload(opts, false))
	} else {
		seqSec = elapsedSec
	}

	p := DataPoint{
		fsIdent:         fs.ident,
		fuseOptions:     fuseOpts,
		workloadOptions: opts,
		parallel:        *parallel,
		elapsedTimeSec:  elapsedSec,
		seqTimeSec:      seqSec,
	}

	fs.Stop()

	printTsv(p.DataRow()...)
	if *parallel {
		printTsv(p.SeqPoint().DataRow()...)
	}
	return
}