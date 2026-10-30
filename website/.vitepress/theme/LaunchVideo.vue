<script setup lang="ts">
import { onMounted, ref } from "vue";

// The videos are optional drop-ins: put <name>.mp4 (and <name>.webm, <name>-poster.png) in website/public/
// (see docs/making-a-video.md). A video that is missing is left out, and with none the home page shows nothing, so it never
// renders a broken player. The probe runs in the browser only; failures (offline, 404, a non-video response) hide that video.
// The paths are bound (not literal) so the template compiler leaves them as runtime URLs instead of bundling them.
const VIDEOS = [
  { name: "beta-4", label: "What is new in beta 4" },
  { name: "launch", label: "What kinhin is" },
];
const available = ref<typeof VIDEOS>([]);
const current = ref("");

const exists = async (url: string) => {
  try {
    const response = await fetch(url, { method: "HEAD" });
    const type = response.headers.get("content-type") ?? "";
    return response.ok && type.startsWith("video/");
  } catch {
    return false;
  }
};

onMounted(async () => {
  const found = await Promise.all(VIDEOS.map(async (video) => ((await exists(`/${video.name}.mp4`)) ? video : null)));
  available.value = found.filter((video): video is (typeof VIDEOS)[number] => video !== null);
  current.value = available.value[0]?.name ?? "";
});
</script>

<template>
  <figure v-if="available.length" class="launch-video">
    <div v-if="available.length > 1" class="launch-video-tabs" role="tablist">
      <button
        v-for="video in available"
        :key="video.name"
        type="button"
        role="tab"
        :aria-selected="current === video.name"
        :class="{ active: current === video.name }"
        @click="current = video.name"
      >
        {{ video.label }}
      </button>
    </div>
    <video :key="current" controls loop playsinline preload="metadata" :poster="`/${current}-poster.png`">
      <source :src="`/${current}.webm`" type="video/webm" />
      <source :src="`/${current}.mp4`" type="video/mp4" />
      <a :href="`/${current}.mp4`">Watch the kinhin video</a>
    </video>
  </figure>
</template>

<style scoped>
.launch-video {
  max-width: 1152px;
  margin: 32px auto;
  padding: 0 24px;
}
.launch-video video {
  display: block;
  width: 100%;
  border-radius: 12px;
  border: 1px solid var(--vp-c-divider);
  background: #fff;
}
.launch-video-tabs {
  display: flex;
  gap: 8px;
  margin-bottom: 12px;
  flex-wrap: wrap;
}
.launch-video-tabs button {
  padding: 6px 14px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 999px;
  background: transparent;
  color: var(--vp-c-text-2);
  font-size: 14px;
  cursor: pointer;
}
.launch-video-tabs button.active {
  border-color: var(--vp-c-brand-1);
  color: var(--vp-c-brand-1);
}
</style>
