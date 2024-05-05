package main

import (
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
)

type Response struct {
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Body    string            `json:"body"`
	BodyLen int               `json:"body_len"`
	Headers map[string]string `json:"headers"`
}

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "Hello, %q", html.EscapeString(r.URL.Path))
	})

	http.HandleFunc("/anything", func(w http.ResponseWriter, r *http.Request) {
		bs, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer r.Body.Close()

		headers := map[string]string{}
		for k, v := range r.Header {
			headers[k] = v[0]
		}

		ret := Response{
			Method:  r.Method,
			Path:    r.URL.Path,
			Body:    string(bs),
			BodyLen: len(bs),
			Headers: headers,
		}
		err = json.NewEncoder(w).Encode(ret)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	})

	log.Println("Listening on :8182")
	log.Fatal(http.ListenAndServe(":8182", nil))
}
