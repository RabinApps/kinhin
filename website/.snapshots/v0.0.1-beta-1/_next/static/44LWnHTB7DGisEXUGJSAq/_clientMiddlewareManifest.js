self.__MIDDLEWARE_MATCHERS = [
  {
    "regexp": "^\\/v0\\.0\\.1-beta-1(?:\\/(_next\\/data\\/[^/]{1,}))?(?:\\/((?!_next\\/|md\\/|api\\/).*))(\\.json|\\.rsc|\\.segments\\/.+\\.segment\\.rsc)?[\\/#\\?]?$",
    "originalSource": "/((?!_next/|md/|api/).*)"
  }
];self.__MIDDLEWARE_MATCHERS_CB && self.__MIDDLEWARE_MATCHERS_CB()