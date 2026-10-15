<script setup lang="ts">
interface Section {
  title: string;
  blurb: string;
  icon: string;
  links: { text: string; href: string }[];
}

const sections: Section[] = [
  {
    title: "Get started",
    blurb: "Install kinhin and run your first job in minutes.",
    icon: "/icons/rocket.svg",
    links: [
      { text: "Quick start", href: "/guide/quick-start" },
      { text: "Install", href: "/guide/install" },
      { text: "Configuration", href: "/guide/config" },
    ],
  },
  {
    title: "Run your fleet",
    blurb: "Runtimes, scaling, toolchains and self-healing.",
    icon: "/icons/fleet.svg",
    links: [
      { text: "Runtimes & routing", href: "/guide/runtimes" },
      { text: "Scaling", href: "/guide/scaling" },
      { text: "Toolchains", href: "/guide/toolchains" },
    ],
  },
  {
    title: "Mobile releases",
    blurb: "TestFlight, Play builds and localized store screenshots.",
    icon: "/icons/screenshot.svg",
    links: [
      { text: "First build tutorial", href: "/guide/mobile-fastlane-tutorial" },
      { text: "Store screenshots", href: "/guide/mobile-screenshots" },
      { text: "Credentials", href: "/guide/mobile-credentials" },
    ],
  },
  {
    title: "Product videos",
    blurb: "Narrated launch videos that rebuild from a config.",
    icon: "/icons/video.svg",
    links: [
      { text: "Add videos to your project", href: "/guide/videos-for-your-project" },
      { text: "Video config", href: "/guide/video-config" },
      { text: "Gallery", href: "/guide/video-gallery" },
    ],
  },
  {
    title: "Reference",
    blurb: "Commands, forges, agents and internals.",
    icon: "/icons/book.svg",
    links: [
      { text: "CLI commands", href: "/cli/commands" },
      { text: "Forges", href: "/guide/forges" },
      { text: "Architecture", href: "/guide/architecture" },
    ],
  },
  {
    title: "Contribute",
    blurb: "Build it, test it, help shape the roadmap.",
    icon: "/icons/code.svg",
    links: [
      { text: "Contributing", href: "/guide/contributing" },
      { text: "Roadmap to v0.1.0", href: "/guide/beta-roadmap" },
      { text: "Support & sponsors", href: "/guide/support" },
    ],
  },
];
</script>

<template>
  <div class="docs-grid">
    <section v-for="s in sections" :key="s.title" class="docs-card">
      <img :src="s.icon" alt="" width="28" height="28" />
      <h3>{{ s.title }}</h3>
      <p>{{ s.blurb }}</p>
      <ul>
        <li v-for="l in s.links" :key="l.href">
          <a :href="l.href">{{ l.text }}</a>
        </li>
      </ul>
    </section>
  </div>
</template>
