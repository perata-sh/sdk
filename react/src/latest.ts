"use client";

import { useEffect, useRef } from "react";

/**
 * A ref that always holds the latest value, so a callback prop can be read
 * from inside an event the script calls later without recreating the component.
 */
export function useLatest<T>(value: T): { readonly current: T } {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  });
  return ref;
}
