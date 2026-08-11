El engine no registra la tarea de migraciones (bug conocido del generador). Copio las migraciones del gem directamente. Primero arreglo el naming del app y reviso la primera migración.


Es un Rails::Engine correcto. Diagnostico si el modelo del engine se autoloadea:

Diagnose MemoryRecord autoload
El app/models del engine no está en el autoload — el engine no se está registrando como railtie al boot. Reviso cómo el gem carga el engine:


Ejecutado 2 comandos
Encontrado. En seis, application.rb hace require "agentkit"; require "agentkit/engine" al boot (así el engine registra sus paths antes de fijar el autoload). En qacaller, agentkit solo se requiere en el initializer (demasiado tarde). Replico el patrón de seis:


Leyó y editado application.rb, ejecutado un comando
+7
-0

