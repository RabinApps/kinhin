<script setup lang="ts">
// The closing block on every search-intent page: where to go next, in one place.
const links = [
  { text: "Quick start", href: "/guide/quick-start", note: "From zero to a working fleet" },
  { text: "Install", href: "/guide/install", note: "Pinned versions, updates and uninstall" },
  { text: "Forge support", href: "/guide/forges", note: "What has been run against a real server" },
  { text: "Why kinhin", href: "/guide/why-kinhin", note: "Why most runners do one job at a time" },
];
</script>

<template>
  <section class="search-next-steps">
    <h2>Next steps</h2>
    <ul>
      <li v-for="link in links" :key="link.href">
        <a :href="link.href">{{ link.text }}</a>: {{ link.note }}
      </li>
    </ul>
  </section>
</template>

<style scoped>
.search-next-steps {
  margin-top: 32px;
  padding: 16px 20px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
}

.search-next-steps h2 {
  margin-top: 0;
  padding-top: 0;
  border-top: 0;
  font-size: 1.2rem;
}

.search-next-steps ul {
  margin-bottom: 0;
}
</style>
