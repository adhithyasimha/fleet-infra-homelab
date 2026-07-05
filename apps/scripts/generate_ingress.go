package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type Metadata struct {
	Name             string `yaml:"name"`
	Namespace        string `yaml:"namespace"`
	Host             string `yaml:"host"`
	Service          string `yaml:"service"`
	Port             int    `yaml:"port"`
	Path             string `yaml:"path"`
	TLS              bool   `yaml:"tls"`
	IngressClassName string `yaml:"ingressClassName"`
}

func main() {
	metadataPath := flag.String("metadata", "", "path to metadata.yaml")
	templatePath := flag.String("template", "apps/templates/ingress.yaml.tmpl", "path to ingress template")
	outputPath := flag.String("output", "", "path to write generated ingress.yaml")
	flag.Parse()

	if *metadataPath == "" || *outputPath == "" {
		fmt.Println("usage: go run apps/scripts/generate_ingress.go -metadata <file> -output <file>")
		os.Exit(1)
	}

	data, err := os.ReadFile(*metadataPath)
	if err != nil {
		panic(err)
	}

	var m Metadata
	if err := yaml.Unmarshal(data, &m); err != nil {
		panic(err)
	}

	tmpl, err := os.ReadFile(*templatePath)
	if err != nil {
		panic(err)
	}

	rendered := string(tmpl)
	rendered = strings.ReplaceAll(rendered, "{{ .Name }}", m.Name)
	rendered = strings.ReplaceAll(rendered, "{{ .Namespace }}", m.Namespace)
	rendered = strings.ReplaceAll(rendered, "{{ .Host }}", m.Host)
	rendered = strings.ReplaceAll(rendered, "{{ .Service }}", m.Service)
	rendered = strings.ReplaceAll(rendered, "{{ .Path }}", m.Path)
	rendered = strings.ReplaceAll(rendered, "{{ .IngressClassName }}", m.IngressClassName)
	rendered = strings.ReplaceAll(rendered, "{{ .Port }}", fmt.Sprintf("%d", m.Port))

	if err := os.MkdirAll(filepath.Dir(*outputPath), 0o755); err != nil {
		panic(err)
	}
	if err := os.WriteFile(*outputPath, []byte(rendered), 0o644); err != nil {
		panic(err)
	}
}
