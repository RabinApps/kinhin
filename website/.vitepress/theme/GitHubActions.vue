<script setup lang="ts">
import { onMounted, ref } from "vue";

const REPO = "RabinApps/kinhin";
const CACHE_KEY = "kinhin:github-stars";
const CACHE_MS = 60 * 60 * 1000;

const stars = ref<string | null>(null);

function format(count: number): string {
  return count >= 1000 ? `${(count / 1000).toFixed(count >= 10000 ? 0 : 1)}k` : String(count);
}

// The count is cosmetic: serve it from a one-hour localStorage cache and show nothing on any failure
// (offline, rate-limited, storage blocked), so the header never breaks.
onMounted(async () => {
  try {
    const cached = JSON.parse(localStorage.getItem(CACHE_KEY) ?? "null");
    if (cached && Date.now() - cached.at < CACHE_MS) {
      stars.value = format(cached.count);
      return;
    }
  } catch {}
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO}`);
    if (!response.ok) return;
    const { stargazers_count: count } = await response.json();
    if (typeof count !== "number") return;
    stars.value = format(count);
    try {
      localStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), count }));
    } catch {}
  } catch {}
});
</script>

<template>
  <div class="github-actions">
    <a
      v-if="stars"
      class="github-stars"
      :href="`https://github.com/${REPO}`"
      target="_blank"
      rel="noopener"
      :aria-label="`${stars} stars on GitHub`"
    >
      <span aria-hidden="true">★</span> {{ stars }}
    </a>
    <a
      class="issue-button"
      :href="`https://github.com/${REPO}/issues/new/choose`"
      target="_blank"
      rel="noopener"
    >
      Report an issue
    </a>
  </div>
</template>

<style scoped>
.github-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: 4px;
}
.github-stars {
  font-size: 13px;
  font-weight: 500;
  color: var(--vp-c-text-2);
  white-space: nowrap;
  transition: color 0.25s;
}
.github-stars:hover {
  color: var(--vp-c-text-1);
}
.issue-button {
  padding: 3px 12px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 14px;
  font-size: 13px;
  font-weight: 500;
  color: var(--vp-c-text-1);
  white-space: nowrap;
  transition: border-color 0.25s;
}
.issue-button:hover {
  border-color: var(--vp-c-text-2);
}
@media (max-width: 767px) {
  .github-actions {
    margin: 12px 0 0;
  }
}
</style>
