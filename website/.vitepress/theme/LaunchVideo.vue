<script setup lang="ts">
import { onMounted, ref } from "vue";

// The launch video is an optional drop-in: put launch.mp4 (and launch.webm, launch-poster.png) in
// website/public/ (see docs/making-a-video.md). Without them nothing renders, so the home page never shows a
// broken player. The probe runs in the browser only; failures (offline, 404, a non-video response) hide it.
// Bound (not literal) so the template compiler leaves them as runtime URLs instead of bundling them.
const VIDEO = "/launch.mp4";
const WEBM = "/launch.webm";
const POSTER = "/launch-poster.png";
const available = ref(false);

onMounted(async () => {
  try {
    const response = await fetch(VIDEO, { method: "HEAD" });
    const type = response.headers.get("content-type") ?? "";
    available.value = response.ok && type.startsWith("video/");
  } catch {
    available.value = false;
  }
});
</script>

<template>
  <figure v-if="available" class="launch-video">
    <video controls muted loop playsinline preload="metadata" :poster="POSTER">
      <source :src="WEBM" type="video/webm" />
      <source :src="VIDEO" type="video/mp4" />
      <a :href="VIDEO">Watch the kinhin launch video</a>
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
</style>
