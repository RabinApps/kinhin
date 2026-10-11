<script setup lang="ts">
import { onMounted, ref } from "vue";

// Two audiences for the same page: a person running the steps, or a person
// handing the job to an AI agent. Both panes are rendered (v-show), so search
// and the built HTML contain both; the choice is remembered across pages.
type Audience = "human" | "agent";
const STORAGE_KEY = "kinhin:audience";
const active = ref<Audience>("human");

onMounted(() => {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "human" || saved === "agent") active.value = saved;
  } catch {}
  if (location.hash === "#with-an-ai-agent") active.value = "agent";
});

function select(audience: Audience): void {
  active.value = audience;
  try {
    localStorage.setItem(STORAGE_KEY, audience);
  } catch {}
}
</script>

<template>
  <div class="audience-tabs">
    <div class="audience-tabs-bar" role="tablist" aria-label="Who is setting kinhin up">
      <button
        type="button"
        role="tab"
        :aria-selected="active === 'human'"
        :class="{ active: active === 'human' }"
        @click="select('human')"
      >
        I'll do it myself
      </button>
      <button
        type="button"
        role="tab"
        :aria-selected="active === 'agent'"
        :class="{ active: active === 'agent' }"
        @click="select('agent')"
      >
        With an AI agent
      </button>
    </div>
    <div v-show="active === 'human'" role="tabpanel" class="audience-tabs-panel">
      <slot name="human" />
    </div>
    <div v-show="active === 'agent'" role="tabpanel" class="audience-tabs-panel">
      <slot name="agent" />
    </div>
  </div>
</template>

<style scoped>
.audience-tabs-bar {
  display: flex;
  gap: 4px;
  margin: 24px 0 8px;
  border-bottom: 1px solid var(--vp-c-divider);
}
.audience-tabs-bar button {
  padding: 8px 14px;
  font-size: 14px;
  font-weight: 600;
  color: var(--vp-c-text-2);
  border-bottom: 2px solid transparent;
  margin-bottom: -1px;
}
.audience-tabs-bar button:hover {
  color: var(--vp-c-text-1);
}
.audience-tabs-bar button.active {
  color: var(--vp-c-brand-1);
  border-bottom-color: var(--vp-c-brand-1);
}
</style>
