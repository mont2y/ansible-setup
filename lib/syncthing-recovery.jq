# Strict schema: reject extra keys so identity, API keys, and runtime state
# cannot accidentally become part of the recovery format.
def text: type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not);
def keys_are($allowed): (keys - $allowed | length) == 0;
def device_id:
  type == "string" and test("^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$") and
  (gsub("-"; "") | . as $id |
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567" as $alphabet |
    (["A", "Q"] | index($id[54:55]) != null) and
    all(range(0;4); . as $block |
      (reduce range(0;13) as $i (0;
        ($alphabet | index($id[$block*14+$i:$block*14+$i+1])) as $n |
        ($n * (1 + ($i % 2))) as $v | . + ($v / 32 | floor) + ($v % 32))) as $sum |
      $id[$block*14+13:$block*14+14] == $alphabet[(32-$sum%32)%32:(32-$sum%32)%32+1]));
def unique_values: length == (unique | length);
def manifest:
  [.devices[]?.alias] as $aliases |
  type == "object" and keys_are(["version","devices","folders"]) and
  .version == 1 and (.devices | type == "array") and (.folders | type == "array") and
  all(.devices[];
    type == "object" and keys_are(["alias","deviceID","name","introducer"]) and
    (.alias | type == "string" and test("^[A-Za-z0-9_-]{1,32}$")) and
    (.deviceID | device_id) and .deviceID != $local_id and
    (.name | text) and (.introducer | type == "boolean")) and
  ([.devices[].alias] | unique_values) and ([.devices[].deviceID] | unique_values) and
  all(.folders[];
    type == "object" and keys_are(["id","label","path","type","devices"]) and
    (.id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$") and startswith("-") == false) and
    (.label | text) and (.path | text) and
    (.type as $t | ["sendreceive","sendonly","receiveonly","receiveencrypted"] | index($t) != null) and
    (.devices | type == "array" and unique_values and all(.[]; . as $a | $aliases | index($a) != null))) and
  ([.folders[].id] | unique_values);
