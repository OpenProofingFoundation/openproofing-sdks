import {fileURLToPath} from 'node:url';
import {checkQualityConfig} from '../../../quality/quality_config.mjs';
checkQualityConfig(fileURLToPath(new URL('../../', import.meta.url)), 'document');
