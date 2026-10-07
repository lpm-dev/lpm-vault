import json
import sys
from pathlib import Path
from release_channels import decorate_feed

if __name__ == '__main__':
    decorate_feed(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()))
