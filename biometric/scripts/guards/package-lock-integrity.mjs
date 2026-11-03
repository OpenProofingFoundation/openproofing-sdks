#!/usr/bin/env node
import {fileURLToPath} from 'node:url';
import {checkLockIntegrity} from '../../../quality/lock_integrity.mjs';
checkLockIntegrity(fileURLToPath(new URL('../../', import.meta.url)));
