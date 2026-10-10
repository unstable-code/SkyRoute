-- busted 실행 전에 불러오는 helper (.busted 의 helper 설정)
--
-- busted 에는 "건너뜀" 상태가 따로 없어 pending() 으로 건너뛴다.
-- 이 저장소에서 pending 은 건너뛰는 용도로만 쓰므로 출력 문구를 skipped 로 바꾼다.
-- 상태 자체는 그대로 pending 이며 표시 문구만 바뀐다.

local s = require("say")

s:set_namespace("en")
s:set("output.pending", "Skipped")
s:set("output.pending_plural", "skipped")
s:set("output.pending_zero", "skipped")
s:set("output.pending_single", "skipped")
