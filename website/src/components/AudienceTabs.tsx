import type { ReactNode } from 'react'
import { TabList } from './TabList'

/** "Do it yourself" / "Hand it to an AI agent": both panels are in the HTML (server-rendered); TabList shows one. */
export function AudienceTabs({ children }: { children: ReactNode }) {
  return (
    <div className="tabs">
      <TabList />
      {children}
    </div>
  )
}
