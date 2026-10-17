package perata

import "iter"

// Page is one page of a list, and where the list ends.
type Page[T any] struct {
	Items      []T        `json:"items"`
	Pagination Pagination `json:"pagination"`
}

// iterate walks pages from first (1 when zero) until the last one, as Polar's
// SDKs do, yielding every item and stopping at the first error.
func iterate[T any](fetch func(page int) (*Page[T], error), first int) iter.Seq2[T, error] {
	return func(yield func(T, error) bool) {
		if first < 1 {
			first = 1
		}
		for page := first; ; page++ {
			result, err := fetch(page)
			if err != nil {
				var zero T
				yield(zero, err)
				return
			}
			for _, item := range result.Items {
				if !yield(item, nil) {
					return
				}
			}
			if page >= int(result.Pagination.MaxPage) {
				return
			}
		}
	}
}
