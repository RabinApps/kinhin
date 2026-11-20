/**
 * Structured data. One `<script>` per object: each carries its own `@context`, which is what consumers (and some browser
 * extensions) expect, rather than a single script holding an array. `<` is escaped so a title can never close the tag.
 */
export function JsonLd({ data }: { data: object | object[] }) {
  return (
    <>
      {[data].flat().map((d, i) => (
        <script key={i} type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(d).replace(/</g, '\\u003c') }} />
      ))}
    </>
  )
}
