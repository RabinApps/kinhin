<script setup lang="ts">
import { computed } from "vue";
import { sponsors } from "../sponsors";

const heading = computed(() =>
  sponsors.length > 0 ? `Sponsored by ${sponsors.map((s) => s.name).join(", ")}` : "Support kinhin",
);
</script>

<template>
  <div class="home-banners vp-doc">
    <div class="warning custom-block">
<!-- docs-sync:begin release-title -->
      <p class="custom-block-title">Beta (v0.0.1-beta-4)</p>
<!-- docs-sync:end release-title -->
      <p>
        Supports <strong>GitHub, Gitea, Forgejo and GitLab CE</strong>. See
        <a href="/guide/forges#what-has-been-tested">what has been tested</a>, the
        <a href="/guide/beta-roadmap">roadmap to v0.1.0</a> and the
        <a href="/blog/beta-4">beta announcement</a>.
        <a href="https://github.com/RabinApps/kinhin/issues/new/choose">Report what you find</a>.
      </p>
    </div>
    <div class="tip custom-block">
      <p class="custom-block-title">{{ heading }}</p>
      <p v-if="sponsors.length > 0">
        kinhin is sponsored by
        <template v-for="(sp, i) in sponsors" :key="sp.name">
          <a :href="sp.url" target="_blank" rel="noopener sponsored">{{ sp.name }}</a
          >, {{ sp.blurb.charAt(0).toLowerCase() + sp.blurb.slice(1) }}<span v-if="i < sponsors.length - 1">; </span>
        </template>.
      </p>
      <p>
        kinhin is free and built by one developer: <a href="/guide/support">donate or sponsor</a>, or
        <a href="/guide/used-by">add your project to the list</a>.
      </p>
    </div>
  </div>
</template>

<style scoped>
.home-banners {
  max-width: 1152px;
  margin: 0 auto;
  padding: 16px 24px 0;
}
</style>
